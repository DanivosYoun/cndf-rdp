# B4: xrdp 0.9.17 (Ubuntu 22.04, OpenSSL 3.0.2) limited to one TLS protocol window, so a
# client can be tested against a TLS 1.0-only / 1.1-only server without a real Windows
# 2003/2008 host (legacy-tls design 5, C5). TLS security layer, no NLA (xrdp has none).
# One image, three profiles chosen at run time by TLS_PROFILE (see entrypoint.sh).
FROM ubuntu:22.04
ARG XRDP_VERSION=0.9.17-2ubuntu2
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      "xrdp=${XRDP_VERSION}" \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /harness/
RUN chmod +x /harness/entrypoint.sh
EXPOSE 3389
ENTRYPOINT ["/harness/entrypoint.sh"]
