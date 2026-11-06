#!/usr/bin/env bash
set -Eeuo pipefail

readonly VERSION='0.2.2-rc.1'
readonly PACKAGE="@deepseek-ai/dsh@${VERSION}"
readonly EXPECTED_INTEGRITY='sha512-ijR9UEVYkG15Q/Q79JzvzLBzQOQfc63VLr9n6flpwHPhr5IKn2UxthnSoto/P9l7qGd7pPvI1Ra6TW7LH3oKpg=='
readonly UNIT_NAME='dsh-web.service'
readonly MARKER='# Managed by dsh-vps-deploy; review before changing.'

: "${DSH_USER:=dsh}"
: "${DSH_HOME:=/var/lib/dsh}"
: "${DSH_PORT:=3080}"
: "${DSH_ENABLE:=yes}"
: "${DSH_PUBLIC_URL:=https://dsh.example.invalid/}"
: "${DSH_TRUSTED_HOST:=dsh.example.invalid}"
: "${DSH_TLS_CERT:=}"
: "${DSH_TLS_KEY:=}"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'run as root (for example: sudo ./install.sh)'
command -v node >/dev/null || fail 'Node.js is required (>= 24.9.0)'
command -v npm >/dev/null || fail 'npm is required'
command -v systemctl >/dev/null || fail 'systemd is required'
node -e 'const [a,b,c]=process.versions.node.split(".").map(Number); if (a<24 || (a===24 && b<9)) process.exit(1)' || fail 'Node.js >= 24.9.0 is required'
[[ $DSH_PORT =~ ^[0-9]+$ && $DSH_PORT -ge 1 && $DSH_PORT -le 65535 ]] || fail 'DSH_PORT must be 1..65535'
[[ $DSH_PUBLIC_URL == https://* || $DSH_PUBLIC_URL == http://* ]] || fail 'DSH_PUBLIC_URL must be an http(s) URL'
[[ -n $DSH_TRUSTED_HOST ]] || fail 'DSH_TRUSTED_HOST is required'
if [[ -n $DSH_TLS_CERT || -n $DSH_TLS_KEY ]]; then
  [[ -n $DSH_TLS_CERT && -n $DSH_TLS_KEY ]] || fail 'DSH_TLS_CERT and DSH_TLS_KEY must be provided together'
  [[ -r $DSH_TLS_CERT && -r $DSH_TLS_KEY ]] || fail 'TLS files must exist and be readable before installation'
fi

if ! id "$DSH_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DSH_HOME" --create-home --shell /usr/sbin/nologin "$DSH_USER"
fi
install -d -o "$DSH_USER" -g "$DSH_USER" -m 0750 "$DSH_HOME"
install -d -o root -g root -m 0750 /etc/dsh

npm_integrity="$(npm view "$PACKAGE" dist.integrity --registry=https://registry.npmjs.org)"
[[ $npm_integrity == "$EXPECTED_INTEGRITY" ]] || fail "npm integrity mismatch for $PACKAGE"
npm install --global --omit=dev --ignore-scripts "$PACKAGE"
DSH_BIN="$(command -v dsh || true)"
[[ -x $DSH_BIN ]] || fail 'dsh was not found after npm installation'

if [[ -e /etc/systemd/system/$UNIT_NAME ]] && ! grep -Fqx "$MARKER" /etc/systemd/system/$UNIT_NAME; then
  fail "/etc/systemd/system/$UNIT_NAME exists and is not managed by this project"
fi

install -d -m 0755 /usr/local/libexec
sed -e "s|@DSH_BIN@|$DSH_BIN|g" > /usr/local/libexec/dsh-web-start < bin/dsh-web-start.sh
chmod 0755 /usr/local/libexec/dsh-web-start

install -m 0644 systemd/dsh-web.service.in /tmp/dsh-web.service.in
sed -e "s|@MARKER@|$MARKER|g" -e "s|@DSH_USER@|$DSH_USER|g" -e "s|@DSH_HOME@|$DSH_HOME|g" -e "s|@DSH_BIN@|$DSH_BIN|g" -e "s|@DSH_PORT@|$DSH_PORT|g" > /etc/systemd/system/$UNIT_NAME < /tmp/dsh-web.service.in
rm -f /tmp/dsh-web.service.in

{
  printf 'DSH_BIN=%q\n' "$DSH_BIN"
  printf 'DSH_PUBLIC_URL=%q\n' "$DSH_PUBLIC_URL"
  printf 'DSH_TRUSTED_HOST=%q\n' "$DSH_TRUSTED_HOST"
  printf 'DSH_PORT=%q\n' "$DSH_PORT"
  printf 'DSH_TLS_CERT=%q\n' "$DSH_TLS_CERT"
  printf 'DSH_TLS_KEY=%q\n' "$DSH_TLS_KEY"
} > /etc/dsh/dsh-web.env
chown root:"$DSH_USER" /etc/dsh/dsh-web.env
chmod 0640 /etc/dsh/dsh-web.env

systemctl daemon-reload
if [[ $DSH_ENABLE == yes ]]; then
  systemctl enable --now "$UNIT_NAME"
fi
printf 'installed %s (%s), unit=%s, user=%s\n' "$PACKAGE" "$DSH_BIN" "$UNIT_NAME" "$DSH_USER"
