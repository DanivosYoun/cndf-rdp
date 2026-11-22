#!/bin/sh
# Creates the one-time user, a self-signed TLS certificate, then runs sesman and xrdp.
# HARNESS_USER / HARNESS_PASS come from run-m4-acceptance.sh (one-time credentials).
set -eu
: "${HARNESS_USER:?}" "${HARNESS_PASS:?}"
id "${HARNESS_USER}" >/dev/null 2>&1 || useradd -m -s /bin/sh "${HARNESS_USER}"
printf '%s:%s\n' "${HARNESS_USER}" "${HARNESS_PASS}" | chpasswd
unset HARNESS_PASS
openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=harness-b3-gfx" \
  -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem 2>/dev/null
chmod 600 /etc/xrdp/key.pem
[ -f /etc/xrdp/rsakeys.ini ] || xrdp-keygen xrdp /etc/xrdp/rsakeys.ini >/dev/null
mkdir -p /var/run/xrdp
xrdp-sesman
exec xrdp --nodaemon
