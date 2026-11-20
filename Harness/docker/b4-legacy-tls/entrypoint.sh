#!/bin/sh
# Starts xrdp in the foreground with the TLS protocol window of TLS_PROFILE:
#   tls10  ssl_protocols=TLSv1             (Windows 2008 / 2008 R2 without KB3080079)
#   tls11  ssl_protocols=TLSv1.1
#   tls12  ssl_protocols=TLSv1.2, TLSv1.3  (control: a modern server)
# Ciphers are the CBC-SHA suites a 2008-era Schannel offers, at SECLEVEL 0 so OpenSSL 3 will
# serve them over TLS 1.0/1.1. No sesman: the connection reaches xrdp's login screen, which
# is enough to show the TLS handshake succeeded and frames flow.
# The certificate is a one-time self-signed pair from run-engine-harness.sh (/certs).
set -eu
case "${TLS_PROFILE:?}" in
  tls10) protocols="TLSv1" ;;
  tls11) protocols="TLSv1.1" ;;
  tls12) protocols="TLSv1.2, TLSv1.3" ;;
  *) echo "unknown TLS_PROFILE ${TLS_PROFILE}" >&2; exit 2 ;;
esac
ciphers="AES128-SHA:AES256-SHA:ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:@SECLEVEL=0"

sed -e "s|^security_layer=.*|security_layer=tls|" \
    -e "s|^certificate=.*|certificate=/certs/b4.pem|" \
    -e "s|^key_file=.*|key_file=/certs/b4-key.pem|" \
    -e "s|^ssl_protocols=.*|ssl_protocols=${protocols}|" \
    -e "s|^#\{0,1\}tls_ciphers=.*|tls_ciphers=${ciphers}|" \
    /etc/xrdp/xrdp.ini > /etc/xrdp/xrdp-b4.ini
grep -E '^(security_layer|certificate|key_file|ssl_protocols|tls_ciphers)=' /etc/xrdp/xrdp-b4.ini >&2

mkdir -p /var/run/xrdp
exec xrdp --nodaemon --config /etc/xrdp/xrdp-b4.ini --port 3389
