#!/usr/bin/env bash
# Generate (or reuse) a self-signed certificate for DSH native TLS.
#
# Usage: gen-selfsigned-cert.sh CERT_DIR MAGICDNS_HOST [SERVICE_GROUP]
# Writes CERT_DIR/dsh.crt and CERT_DIR/dsh.key.
set -Eeuo pipefail

: "${DSH_TLS_DAYS:=3650}"
: "${DSH_TLS_KEY_TYPE:=rsa2048}"
: "${DSH_TLS_RENEW_BEFORE_DAYS:=30}"
: "${DSH_TLS_CERT_NAME:=dsh.crt}"
: "${DSH_TLS_KEY_NAME:=dsh.key}"

cert_gen_usage() {
  printf 'usage: %s CERT_DIR MAGICDNS_HOST [SERVICE_GROUP]\n' "$0" >&2
  exit 64
}

cert_expiry_epoch() {
  local cert=$1 enddate
  enddate=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null) || return 1
  date -u -d "${enddate#notAfter=}" +%s 2>/dev/null
}

cert_days_left() {
  local cert=$1 expires now
  expires=$(cert_expiry_epoch "$cert") || { printf '0'; return 0; }
  now=$(date -u +%s)
  printf '%s' "$(((expires - now) / 86400))"
}

cert_covers_host() {
  local cert=$1 host=$2 sans
  sans=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null) || return 1
  printf '%s\n' "$sans" | grep -Fq "DNS:${host}"
}

cert_posture_ok() {
  local dir=$1 cert=$2 key=$3 group=$4
  [[ $(stat -c '%a' "$dir") == 750 ]] || return 1
  [[ $(stat -c '%a' "$cert") == 644 ]] || return 1
  [[ $(stat -c '%a' "$key") == 640 ]] || return 1
  # The directory group is the service group so the daemon can traverse, but
  # the directory itself is still not writable by it.
  [[ $(stat -c '%U' "$dir") == root && $(stat -c '%G' "$dir") == "$group" ]] || return 1
  [[ $(stat -c '%U' "$cert") == root && $(stat -c '%G' "$cert") == root ]] || return 1
  [[ $(stat -c '%U' "$key") == root && $(stat -c '%G' "$key") == "$group" ]] || return 1
}

# gen_selfsigned_cert CERT_DIR HOST [GROUP] [--force]
gen_selfsigned_cert() {
  local dir='' host='' group='' force=no arg
  for arg in "$@"; do
    case "$arg" in
      --force) force=yes;;
      *) if [[ -z $dir ]]; then dir=$arg; elif [[ -z $host ]]; then host=$arg; elif [[ -z $group ]]; then group=$arg; fi;;
    esac
  done
  [[ -n $dir && -n $host ]] || cert_gen_usage
  command -v openssl >/dev/null || { printf 'error: openssl is required to generate native TLS certificates\n' >&2; return 1; }
  [[ $host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { printf 'error: refusing unsafe certificate host name: %s\n' "$host" >&2; return 1; }
  [[ $DSH_TLS_DAYS =~ ^[0-9]+$ ]] || { printf 'error: DSH_TLS_DAYS must be an integer\n' >&2; return 1; }

  local group_name='root'
  if [[ -n $group ]]; then
    group_name=$(id -gn "$group" 2>/dev/null) || { printf 'error: unknown service user: %s\n' "$group" >&2; return 1; }
  fi

  local cert="$dir/${DSH_TLS_CERT_NAME}" key="$dir/${DSH_TLS_KEY_NAME}"
  install -d -o root -g "$group_name" -m 0750 "$dir" || return 1

  if [[ $force == no && -r $cert && -r $key ]] &&
     cert_covers_host "$cert" "$host" &&
     [[ $(cert_days_left "$cert") -gt $DSH_TLS_RENEW_BEFORE_DAYS ]] &&
     openssl pkey -in "$key" -noout >/dev/null 2>&1; then
    chown root:"$group_name" "$key" 2>/dev/null || true
    chmod 0640 "$key"
    chmod 0644 "$cert"
    cert_posture_ok "$dir" "$cert" "$key" "$group_name" || { printf 'error: existing certificate permissions could not be tightened\n' >&2; return 1; }
    printf 'reusing certificate %s (SAN covers %s, %s days left)\n' "$cert" "$host" "$(cert_days_left "$cert")" >&2
    return 0
  fi

  # Generated inside the target directory so the key never crosses a filesystem
  # boundary in world-readable form; umask keeps the temporary key private.
  local tmp_dir
  tmp_dir=$(mktemp -d "$dir/.dsh-tls.XXXXXX") || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN
  cat > "$tmp_dir/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${host}
[v3]
subjectAltName = DNS:${host},DNS:localhost,IP:127.0.0.1
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
CNF
  (
    umask 077
    case "$DSH_TLS_KEY_TYPE" in
      rsa2048)
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DSH_TLS_DAYS" \
          -config "$tmp_dir/openssl.cnf" -keyout "$tmp_dir/key.pem" -out "$tmp_dir/cert.pem" >/dev/null 2>&1
        ;;
      ecdsa)
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days "$DSH_TLS_DAYS" \
          -config "$tmp_dir/openssl.cnf" -keyout "$tmp_dir/key.pem" -out "$tmp_dir/cert.pem" >/dev/null 2>&1
        ;;
      *) printf 'error: DSH_TLS_KEY_TYPE must be rsa2048 or ecdsa\n' >&2; exit 1;;
    esac
  ) || { printf 'error: openssl could not generate the certificate\n' >&2; return 1; }

  openssl x509 -in "$tmp_dir/cert.pem" -noout >/dev/null 2>&1 || { printf 'error: generated certificate is unreadable\n' >&2; return 1; }
  openssl pkey -in "$tmp_dir/key.pem" -noout >/dev/null 2>&1 || { printf 'error: generated private key is unreadable\n' >&2; return 1; }
  cert_covers_host "$tmp_dir/cert.pem" "$host" || { printf 'error: generated certificate is missing the SAN for %s\n' "$host" >&2; return 1; }

  install -o root -g root -m 0644 "$tmp_dir/cert.pem" "$cert" || return 1
  install -o root -g "$group_name" -m 0640 "$tmp_dir/key.pem" "$key" || return 1
  rm -rf "$tmp_dir"
  trap - RETURN
  cert_posture_ok "$dir" "$cert" "$key" "$group_name" || { printf 'error: certificate permissions are not minimal\n' >&2; return 1; }
  printf 'generated self-signed certificate %s (SAN: DNS:%s, DNS:localhost, IP:127.0.0.1, %s days)\n' "$cert" "$host" "$DSH_TLS_DAYS" >&2
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  gen_selfsigned_cert "$@"
fi
