#!/bin/bash
# adcs-request-cert.sh
#
# Generates a private key + CSR (with SAN entries for DNS names and/or IPs),
# submits it to a Microsoft ADCS server's Web Enrollment role
# (http[s]://<ca-host>/certsrv), and retrieves the signed certificate plus
# the CA chain.
#
# Requires the ADCS "Certification Authority Web Enrollment" role feature to
# be installed on the CA (or an IIS server proxying to it) and reachable
# from this host. Output file names match what docker-compose.yml expects,
# so this is a drop-in replacement for generate-certs.sh once a real CA is
# available: keycloak-tls.key, keycloak-tls.crt, ca-bundle.crt.
#
# Usage (interactive — prompts for anything not passed as a flag):
#   ./adcs-request-cert.sh
#
# Usage (non-interactive, e.g. for scripted/reproducible runs):
#   ./adcs-request-cert.sh \
#     --cn keycloak.internal.domain \
#     --dns localhost \
#     --ip 192.168.10.81,127.0.0.1 \
#     --ca-server pki.internal.domain \
#     --template WebServer \
#     --auth ntlm --user 'DOMAIN\svc-keycloak-enroll' \
#     --scheme https --insecure
#
# Retrieve a certificate later, after a pending request was approved:
#   ./adcs-request-cert.sh --retrieve-only --req-id 42 \
#     --ca-server pki.internal.domain --scheme https --insecure
#
# Notes:
#   - --template must be the certificate template's internal *name* (e.g.
#     "WebServer"), not its display name ("Web Server") — check with
#     `certutil -CATemplates` on the CA if unsure.
#   - --auth negotiate uses your existing Kerberos ticket (run `kinit` first);
#     ntlm/basic prompt for a password (or read $ADCS_PASSWORD if set —
#     avoid passing it as a flag, it would be visible in `ps`).
#   - basic auth sends credentials base64-encoded, not encrypted — only use
#     it with --scheme https.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_PATH="/certsrv"
SCHEME="https"
AUTH="ntlm"
KEY_SIZE=2048
INSECURE=0
NON_INTERACTIVE=0
RETRIEVE_ONLY=0
REQ_ID=""
CN=""
DNS_LIST=""
IP_LIST=""
CA_SERVER=""
TEMPLATE=""
AD_USER=""
OUT_NAME="keycloak-tls"

usage() { grep '^#' "${BASH_SOURCE[0]}" | sed -n '2,/^set -e/p' | sed '$d; s/^# \{0,1\}//'; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --cn) CN="$2"; shift 2 ;;
    --dns) DNS_LIST="$2"; shift 2 ;;
    --ip) IP_LIST="$2"; shift 2 ;;
    --ca-server) CA_SERVER="$2"; shift 2 ;;
    --ca-path) CA_PATH="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --auth) AUTH="$2"; shift 2 ;;          # ntlm | negotiate | basic
    --user) AD_USER="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;      # http | https
    --insecure) INSECURE=1; shift ;;
    --key-size) KEY_SIZE="$2"; shift 2 ;;
    --out-name) OUT_NAME="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --retrieve-only) RETRIEVE_ONLY=1; shift ;;
    --req-id) REQ_ID="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

cd "$OUT_DIR"

# ---------------------------------------------------------------------------
# Interactive prompts for anything still unset
# ---------------------------------------------------------------------------
prompt() { # prompt VAR "question" "default"
  local __var="$1" __q="$2" __def="${3:-}" __ans
  if [ "$NON_INTERACTIVE" -eq 1 ]; then return; fi
  if [ -n "${!__var}" ]; then return; fi
  if [ -n "$__def" ]; then
    read -r -p "$__q [$__def]: " __ans
    printf -v "$__var" '%s' "${__ans:-$__def}"
  else
    read -r -p "$__q: " __ans
    printf -v "$__var" '%s' "$__ans"
  fi
}

if [ "$RETRIEVE_ONLY" -eq 0 ]; then
  prompt CN "Certificate Common Name / primary hostname (e.g. keycloak.internal.domain)"
  prompt DNS_LIST "Additional DNS SANs, comma-separated (blank for none)" "localhost"
  prompt IP_LIST "IP SANs, comma-separated (blank for none)" "127.0.0.1"
  prompt TEMPLATE "ADCS certificate template name (internal name, not display name)" "WebServer"
fi
prompt CA_SERVER "ADCS server hostname/IP (Web Enrollment role)"
if [ "$RETRIEVE_ONLY" -eq 1 ]; then
  prompt REQ_ID "Request ID to retrieve"
fi

if [ -z "$CA_SERVER" ]; then echo "ERROR: --ca-server is required." >&2; exit 1; fi
if [ "$RETRIEVE_ONLY" -eq 0 ] && { [ -z "$CN" ] || [ -z "$TEMPLATE" ]; }; then
  echo "ERROR: --cn and --template are required to submit a request." >&2; exit 1
fi
if [ "$RETRIEVE_ONLY" -eq 1 ] && [ -z "$REQ_ID" ]; then
  echo "ERROR: --req-id is required with --retrieve-only." >&2; exit 1
fi

BASE_URL="${SCHEME}://${CA_SERVER}${CA_PATH}"

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
CURL_AUTH_ARGS=()
case "$AUTH" in
  negotiate)
    if ! command -v klist >/dev/null 2>&1 || ! klist -s 2>/dev/null; then
      echo "WARNING: no active Kerberos ticket found (run 'kinit <user>@REALM' first)." >&2
    fi
    CURL_AUTH_ARGS=(--negotiate -u :)
    ;;
  ntlm|basic)
    prompt AD_USER "Username for ${AUTH} auth (e.g. DOMAIN\\\\svc-account)"
    if [ -n "${ADCS_PASSWORD:-}" ]; then
      AD_PASS="$ADCS_PASSWORD"
    else
      read -r -s -p "Password for ${AD_USER}: " AD_PASS; echo
    fi
    CURL_AUTH_ARGS=("--${AUTH}" -u "${AD_USER}:${AD_PASS}")
    ;;
  *)
    echo "ERROR: --auth must be ntlm, negotiate, or basic." >&2; exit 1 ;;
esac

CURL_TLS_ARGS=()
[ "$SCHEME" = "https" ] && [ "$INSECURE" -eq 1 ] && CURL_TLS_ARGS=(-k)

curl_ca() { curl -sS "${CURL_AUTH_ARGS[@]}" "${CURL_TLS_ARGS[@]}" "$@"; }

# ---------------------------------------------------------------------------
# Retrieve-only path (a previously submitted request that needed manual
# approval, now approved by a CA manager)
# ---------------------------------------------------------------------------
fetch_issued_cert() { # fetch_issued_cert <req_id>
  local id="$1"
  echo "==> Downloading signed certificate (ReqID=${id})"
  curl_ca "${BASE_URL}/certnew.cer?ReqID=${id}&Enc=b64" -o "${OUT_NAME}.crt"
  if ! grep -q "BEGIN CERTIFICATE" "${OUT_NAME}.crt"; then
    echo "ERROR: response did not contain a certificate — request may still be pending or was denied." >&2
    echo "Response saved to ${OUT_NAME}.crt for inspection." >&2
    exit 1
  fi

  echo "==> Downloading CA chain"
  curl_ca "${BASE_URL}/certnew.p7b?ReqID=${id}&Renewal=0&Enc=b64" -o chain.p7b.pem
  openssl pkcs7 -in chain.p7b.pem -print_certs -out full-chain.pem
  rm -f chain.p7b.pem

  # The p7b response includes the leaf cert alongside the CA chain; keep
  # ca-bundle.crt as pure CA certs (root + any intermediates) by dropping
  # whichever entry matches the leaf's fingerprint.
  local split_dir leaf_fp fp f
  split_dir="$(mktemp -d)"
  awk -v dir="$split_dir" '/-----BEGIN CERTIFICATE-----/{n++} {print > sprintf("%s/cert-%02d.pem", dir, n)}' full-chain.pem
  leaf_fp="$(openssl x509 -in "${OUT_NAME}.crt" -noout -fingerprint -sha256)"
  : > ca-bundle.crt
  for f in "$split_dir"/cert-*.pem; do
    fp="$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null || true)"
    [ "$fp" = "$leaf_fp" ] && continue
    cat "$f" >> ca-bundle.crt
  done
  rm -rf "$split_dir" full-chain.pem

  chmod 644 "${OUT_NAME}.crt" ca-bundle.crt
  echo "==> Done:"
  ls -l "${OUT_NAME}.crt" ca-bundle.crt
  openssl x509 -in "${OUT_NAME}.crt" -noout -subject -issuer -dates
}

if [ "$RETRIEVE_ONLY" -eq 1 ]; then
  fetch_issued_cert "$REQ_ID"
  exit 0
fi

# ---------------------------------------------------------------------------
# Build openssl.cnf with SANs, generate key + CSR
# ---------------------------------------------------------------------------
echo "==> Building openssl.cnf for CN=${CN}"

SAN_LINES=""
i=1
IFS=',' read -ra DNS_ARR <<< "$DNS_LIST"
for d in "${DNS_ARR[@]}"; do
  d="$(echo "$d" | xargs)"; [ -z "$d" ] && continue
  SAN_LINES+="DNS.${i} = ${d}"$'\n'; i=$((i+1))
done
# Always include the CN itself as a SAN (modern clients ignore CN otherwise)
SAN_LINES+="DNS.${i} = ${CN}"$'\n'; i=$((i+1))

j=1
IFS=',' read -ra IP_ARR <<< "$IP_LIST"
for ip in "${IP_ARR[@]}"; do
  ip="$(echo "$ip" | xargs)"; [ -z "$ip" ] && continue
  SAN_LINES+="IP.${j} = ${ip}"$'\n'; j=$((j+1))
done

cat > openssl.cnf <<EOF
[ req ]
default_bits       = ${KEY_SIZE}
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
CN = ${CN}

[ req_ext ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
${SAN_LINES}
EOF

echo "==> Generating key + CSR"
openssl genrsa -out "${OUT_NAME}.key" "$KEY_SIZE"
chmod 600 "${OUT_NAME}.key"
openssl req -new -key "${OUT_NAME}.key" -config openssl.cnf -out "${OUT_NAME}.csr"

echo "==> CSR SANs:"
openssl req -in "${OUT_NAME}.csr" -noout -text | grep -A1 "Subject Alternative Name" || true

# ---------------------------------------------------------------------------
# Submit to ADCS Web Enrollment (certsrv)
# ---------------------------------------------------------------------------
echo "==> Submitting CSR to ${BASE_URL} (template: ${TEMPLATE})"

# certsrv's ASP form expects CRLF line endings in the CSR field.
CSR_CRLF_FILE="$(mktemp)"
sed 's/$/\r/' "${OUT_NAME}.csr" > "$CSR_CRLF_FILE"

RESPONSE_FILE="$(mktemp)"
curl_ca \
  --data-urlencode "Mode=newreq" \
  --data-urlencode "CertRequest@${CSR_CRLF_FILE}" \
  --data-urlencode "CertAttrib=CertificateTemplate:${TEMPLATE}" \
  --data-urlencode "TargetStoreFlags=0" \
  --data-urlencode "SaveCert=yes" \
  "${BASE_URL}/certfnsh.asp" -o "$RESPONSE_FILE"
rm -f "$CSR_CRLF_FILE"

if grep -qi "denied" "$RESPONSE_FILE"; then
  echo "ERROR: request was denied by the CA. Response:" >&2
  sed 's/<[^>]*>//g' "$RESPONSE_FILE" | grep -vi '^\s*$' | head -20 >&2
  exit 1
fi

ID="$(grep -oP 'ReqID=\K[0-9]+' "$RESPONSE_FILE" | head -1 || true)"
if [ -z "$ID" ]; then
  ID="$(grep -oP 'Request Id is \K[0-9]+' "$RESPONSE_FILE" | head -1 || true)"
fi

if [ -z "$ID" ]; then
  echo "ERROR: could not find a request ID in the CA's response. Raw response saved to $RESPONSE_FILE for inspection." >&2
  echo "First lines:" >&2
  sed 's/<[^>]*>//g' "$RESPONSE_FILE" | grep -vi '^\s*$' | head -20 >&2
  exit 1
fi

if grep -qi "pending" "$RESPONSE_FILE"; then
  echo "==> Request ${ID} is PENDING manual approval by a certificate manager."
  echo "    Once approved, retrieve it with:"
  echo "    $0 --retrieve-only --req-id ${ID} --ca-server ${CA_SERVER} --scheme ${SCHEME} --ca-path ${CA_PATH} $( [ "$INSECURE" -eq 1 ] && echo --insecure )"
  rm -f "$RESPONSE_FILE"
  exit 0
fi

rm -f "$RESPONSE_FILE"
fetch_issued_cert "$ID"
