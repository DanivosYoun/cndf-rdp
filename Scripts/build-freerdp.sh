#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${ROOT_DIR}/Vendor/FreeRDP/src"
BUILD_DIR="${ROOT_DIR}/Vendor/FreeRDP/build"
INSTALL_DIR="${ROOT_DIR}/Vendor/FreeRDP/install"
FREERDP_REPO="https://github.com/FreeRDP/FreeRDP.git"
FREERDP_COMMIT="bf217a504e54cc719880c228e82353382cd7d4fa"

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  mkdir -p "$(dirname "${SRC_DIR}")"
  git clone --depth 1 --branch 3.32.1 "${FREERDP_REPO}" "${SRC_DIR}"
fi

git -C "${SRC_DIR}" fetch --depth 1 origin tag 3.32.1
git -C "${SRC_DIR}" checkout --detach "${FREERDP_COMMIT}"
git -C "${SRC_DIR}" reset --hard "${FREERDP_COMMIT}"

git -C "${SRC_DIR}" apply <<'PATCH'
diff --git a/channels/cliprdr/client/cliprdr_main.c b/channels/cliprdr/client/cliprdr_main.c
--- a/channels/cliprdr/client/cliprdr_main.c
+++ b/channels/cliprdr/client/cliprdr_main.c
@@ -706,11 +706,12 @@ static UINT cliprdr_client_format_list(CliprdrClientContext* context,
 			const CLIPRDR_FORMAT* format = &filterList.formats[x];
 			WLog_Print(cliprdr->log, level, "[%" PRIuz "]: id=0x%08" PRIx32 " [%s|%s]", x,
 			           format->formatId, ClipboardGetFormatIdString(format->formatId),
 			           format->formatName);
 		}
 	}
 
-	s = cliprdr_packet_format_list_new(&filterList, cliprdr->useLongFormatNames, FALSE);
+	s = cliprdr_packet_format_list_new(&filterList, cliprdr->useLongFormatNames,
+	                                   !cliprdr->useLongFormatNames);
 	cliprdr_free_format_list(&filterList);
 
 	if (!s)
PATCH

cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DBUILD_SHARED_LIBS=ON \
  -DWITH_CLIENT_COMMON=ON \
  -DWITH_CLIENT=OFF \
  -DWITH_CLIENT_SDL=OFF \
  -DWITH_SERVER=OFF \
  -DWITH_CHANNELS=ON \
  -DWITH_CLIENT_CHANNELS=ON \
  -DWITH_SAMPLE=OFF \
  -DWITH_MANPAGES=OFF \
  -DBUILD_TESTING=OFF \
  -DWITH_X11=OFF \
  -DWITH_WAYLAND=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_DSP_FFMPEG=OFF \
  -DWITH_OPUS=OFF \
  -DWITH_SWSCALE=OFF \
  -DWITH_CAIRO=OFF \
  -DWITH_JPEG=OFF \
  -DWITH_PCSC=OFF \
  -DWITH_CUPS=OFF \
  -DWITH_FUSE=OFF \
  -DWITH_MACAUDIO=ON \
  -DWITH_OPENH264=OFF \
  -DWITH_WEBVIEW=OFF \
  -DWITH_AAD=OFF \
  -DWITH_INTERNAL_MD4=ON \
  -DWITH_INTERNAL_MD5=ON \
  -DWITH_VERBOSE_WINPR_ASSERT=OFF \
  -DCHANNEL_CLIPRDR_CLIENT=ON \
  -DCHANNEL_DRDYNVC_CLIENT=ON \
  -DCHANNEL_DISP_CLIENT=ON \
  -DCHANNEL_RDPSND=ON \
  -DCHANNEL_AUDIN=OFF \
  -DCHANNEL_URBDRC=OFF \
  -DCHANNEL_SMARTCARD=OFF \
  -DCHANNEL_PRINTER=OFF \
  -DCHANNEL_SERIAL=OFF \
  -DCHANNEL_PARALLEL=OFF

cmake --build "${BUILD_DIR}" --target install --parallel "$(sysctl -n hw.ncpu)"
