#!/bin/bash
# generate-certs.sh
#
# Generates a self-signed internal CA plus a leaf certificate for Keycloak's
# HTTPS listener. In the real air-gapped environment, replace this with certs
# issued by the internal PKI/CA if one exists; this script is here so the
# test environment (and a disconnected env with no PKI at all) can still
# stand up TLS end-to-end.
#
# Usage: ./generate-certs.sh <hostname> [extra-ip] [extra-dns]
set -euo pipefail

HOSTNAME="${1:?Usage: $0 <hostname> [extra-ip] [extra-dns]}"
EXTRA_IP="${2:-}"
EXTRA_DNS="${3:-}"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAYS_CA=3650
DAYS_CERT=825   # keep under the 825-day CA/Browser Forum ceiling

cd "$OUT_DIR"

echo "==> Generating internal CA (valid ${DAYS_CA} days)"
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days "$DAYS_CA" \
  -subj "/C=US/O=Internal Test Lab/CN=Internal Test Lab Root CA" \
  -out ca.crt

echo "==> Generating Keycloak server key + CSR for CN=${HOSTNAME}"
openssl genrsa -out keycloak-tls.key 2048

SAN="DNS:${HOSTNAME},DNS:localhost,IP:127.0.0.1"
[ -n "$EXTRA_IP" ] && SAN="${SAN},IP:${EXTRA_IP}"
[ -n "$EXTRA_DNS" ] && SAN="${SAN},DNS:${EXTRA_DNS}"

openssl req -new -key keycloak-tls.key \
  -subj "/C=US/O=Internal Test Lab/CN=${HOSTNAME}" \
  -out keycloak-tls.csr

cat > keycloak-tls.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${SAN}
EOF

echo "==> Signing Keycloak server cert (valid ${DAYS_CERT} days, SAN=${SAN})"
openssl x509 -req -in keycloak-tls.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out keycloak-tls.crt -days "$DAYS_CERT" -sha256 \
  -extfile keycloak-tls.ext

cp ca.crt ca-bundle.crt

chmod 600 ca.key keycloak-tls.key
chmod 644 ca.crt ca-bundle.crt keycloak-tls.crt
rm -f keycloak-tls.csr keycloak-tls.ext

echo "==> Done. Files in ${OUT_DIR}:"
ls -l ca.crt ca-bundle.crt keycloak-tls.crt keycloak-tls.key

echo
echo "Verify:"
echo "  openssl x509 -in keycloak-tls.crt -noout -text | grep -A1 'Subject Alternative Name'"
