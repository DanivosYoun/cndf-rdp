# B2: FreeRDP 3.33.1 shadow server on Xvfb, an independent RDP server implementation
# (design D7 H-B2). NTLM NLA through a SAM file, GFX (Progressive / AVC444 via ffmpeg),
# and a Tk probe window whose square changes colour on every key press (input->display).
# x11-apps provides xwd for the M4 reference screen capture (Harness/docker/m4).
FROM debian:13 AS build
ARG FREERDP_TAG=3.33.1
ARG FREERDP_COMMIT=65bcca1913a28cbdd7eb913599f692bd2b707991
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates git build-essential cmake ninja-build pkg-config \
      libssl-dev zlib1g-dev libjson-c-dev libcjson-dev libicu-dev \
      libx11-dev libxext-dev libxfixes-dev libxdamage-dev libxtst-dev libxinerama-dev \
      libxrandr-dev libxkbfile-dev libxcursor-dev libxi-dev libxrender-dev libxv-dev \
      libavcodec-dev libavutil-dev libswscale-dev libswresample-dev \
 && rm -rf /var/lib/apt/lists/*
RUN git clone -q --depth 1 --branch "${FREERDP_TAG}" https://github.com/FreeRDP/FreeRDP.git /src \
 && test "$(git -C /src rev-parse HEAD)" = "${FREERDP_COMMIT}"
RUN cmake -S /src -B /build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/freerdp \
      -DWITH_SERVER=ON -DWITH_SHADOW=ON -DWITH_SHADOW_X11=ON -DWITH_PROXY=OFF \
      -DWITH_SAMPLE=OFF -DWITH_PLATFORM_SERVER=OFF \
      -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_X11=OFF \
      -DWITH_X11=ON -DWITH_WAYLAND=OFF -DWITH_FFMPEG=ON -DWITH_DSP_FFMPEG=OFF -DWITH_SWSCALE=ON \
      -DWITH_OPENH264=OFF -DWITH_CAIRO=OFF -DWITH_JPEG=OFF -DWITH_PCSC=OFF -DWITH_CUPS=OFF \
      -DWITH_FUSE=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF -DWITH_OPUS=OFF \
      -DWITH_KRB5=OFF -DWITH_PKCS11=OFF -DWITH_AAD=OFF -DWITH_WEBVIEW=OFF -DWITH_MANPAGES=OFF \
      -DWITH_INTERNAL_RC4=ON -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON \
      -DCHANNEL_URBDRC=OFF -DBUILD_TESTING=OFF \
 && cmake --build /build --target install

FROM debian:13
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libssl3t64 zlib1g libjson-c5 libcjson1 libicu76 \
      libx11-6 libxext6 libxfixes3 libxdamage1 libxtst6 libxinerama1 libxrandr2 libxkbfile1 \
      libxcursor1 libxi6 libxrender1 libxv1 \
      libavcodec61 libavutil59 libswscale8 libswresample5 \
      xvfb python3-tk procps x11-apps \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/freerdp /opt/freerdp
ENV LD_LIBRARY_PATH=/opt/freerdp/lib PATH=/opt/freerdp/bin:$PATH
COPY probe.py entrypoint.sh /harness/
RUN chmod +x /harness/entrypoint.sh
EXPOSE 3389
ENTRYPOINT ["/harness/entrypoint.sh"]
