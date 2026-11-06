#!/usr/bin/env bash
# Atomically replace native DSH TLS files, then reload only dsh-web.service.
set -Eeuo pipefail

: "${DSH_UNIT:=dsh-web.service}"
cert=${1:-${DSH_TLS_CERT:-}}
key=${2:-${DSH_TLS_KEY:-}}
[[ -n $cert && -n $key ]] || { printf 'usage: %s CERT KEY\n' "$0" >&2; exit 64; }
[[ -r $cert && -r $key ]] || { printf 'error: source certificate/key must be readable\n' >&2; exit 1; }
command -v openssl >/dev/null || { printf 'error: openssl is required for certificate validation\n' >&2; exit 1; }
command -v systemctl >/dev/null || { printf 'error: systemctl is required\n' >&2; exit 1; }

cert_dir=$(dirname -- "$cert")
key_dir=$(dirname -- "$key")
[[ $cert_dir == "$key_dir" ]] || { printf 'error: certificate and key must share a directory for an atomic generation swap\n' >&2; exit 1; }
install -d -m 0750 "$cert_dir"
tmp_dir=$(mktemp -d "$cert_dir/.dsh-tls.XXXXXX")
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
install -m 0644 "$cert" "$tmp_dir/cert.pem"
install -m 0640 "$key" "$tmp_dir/key.pem"
openssl x509 -in "$tmp_dir/cert.pem" -noout >/dev/null
openssl pkey -in "$tmp_dir/key.pem" -noout >/dev/null
cert_pub=$(openssl x509 -in "$tmp_dir/cert.pem" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)
key_pub=$(openssl pkey -in "$tmp_dir/key.pem" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)
[[ $cert_pub == "$key_pub" ]] || { printf 'error: certificate and key do not match\n' >&2; exit 1; }

# Each rename is atomic; validation happens before either destination changes.
mv -f "$tmp_dir/cert.pem" "$cert"
mv -f "$tmp_dir/key.pem" "$key"
systemctl reload "$DSH_UNIT"
printf 'reloaded %s with validated native TLS files\n' "$DSH_UNIT"
