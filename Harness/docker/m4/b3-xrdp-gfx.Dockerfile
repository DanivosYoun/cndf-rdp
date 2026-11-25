# B3-GFX: xrdp 0.10.5 + xorgxrdp 0.10.5 built with x264, so the server sends RDPGFX AVC420
# (design m4-h264-design A1). The pinned M1 B3 image (danielguerra/ubuntu-xrdp, xrdp 0.9.5)
# has no GFX, and Debian 13's xrdp package is built without an H.264 encoder.
# The session runs animator.py only (no window manager); xwd captures the reference screen.
# Build context: Harness/docker/m4.
FROM debian:13 AS build
ARG XRDP_TAG=v0.10.5
ARG XRDP_COMMIT=22f2345e9cb3e42aa82d4aa96a66f331d6e762d8
ARG XORGXRDP_TAG=v0.10.5
ARG XORGXRDP_COMMIT=c2d3cbafebe00be3221f985c06ef6b97f1c63790
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates git build-essential autoconf automake libtool pkg-config nasm \
      libssl-dev libpam0g-dev libx11-dev libxfixes-dev libxrandr-dev libjpeg-dev \
      libx264-dev xserver-xorg-dev libepoxy-dev \
 && rm -rf /var/lib/apt/lists/*
RUN git clone -q --depth 1 --branch "${XRDP_TAG}" --recursive https://github.com/neutrinolabs/xrdp.git /src/xrdp \
 && test "$(git -C /src/xrdp rev-parse HEAD)" = "${XRDP_COMMIT}" \
 && git clone -q --depth 1 --branch "${XORGXRDP_TAG}" https://github.com/neutrinolabs/xorgxrdp.git /src/xorgxrdp \
 && test "$(git -C /src/xorgxrdp rev-parse HEAD)" = "${XORGXRDP_COMMIT}"
RUN cd /src/xrdp && ./bootstrap && ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
      --enable-x264 \
 && make -j"$(nproc)" && make install DESTDIR=/out \
 && cd /src/xorgxrdp && ./bootstrap && PKG_CONFIG_PATH=/out/usr/lib/pkgconfig ./configure --prefix=/usr \
      CFLAGS="-I/out/usr/include" \
 && make -j"$(nproc)" && make install DESTDIR=/out

FROM debian:13
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libssl3t64 libpam0g libx11-6 libxfixes3 libxrandr2 libjpeg62-turbo libx264-164 libepoxy0 \
      xserver-xorg-core xauth openssl python3-tk x11-apps procps \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /
COPY animator.py /opt/m4/animator.py
COPY b3-entrypoint.sh /opt/m4/entrypoint.sh
RUN chmod 755 /opt/m4/entrypoint.sh \
 && printf '#!/bin/sh\nexec python3 /opt/m4/animator.py\n' > /etc/xrdp/startwm.sh \
 && chmod 755 /etc/xrdp/startwm.sh
EXPOSE 3389
ENTRYPOINT ["/opt/m4/entrypoint.sh"]
