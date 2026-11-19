#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$ROOT_DIR/Vendor/FreeRDP/install"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir "$WORK_DIR/modules"

# Model the packaged app on a Mac without Homebrew's legacy provider module.
# RFC 6229's 128-bit RC4 vector exercises the same WinPR API as NTLM sealing.
cat > "$WORK_DIR/test.c" <<'C'
#include <stdio.h>
#include <string.h>
#include <winpr/custom-crypto.h>
#include <winpr/ssl.h>

int main(void)
{
    const BYTE key[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
    const BYTE expected[] = {
        0x9a, 0xc7, 0xcc, 0x9a, 0x60, 0x9d, 0x1e, 0xf7,
        0xb2, 0x93, 0x28, 0x99, 0xcd, 0xe4, 0x1b, 0x97
    };
    const BYTE input[sizeof(expected)] = {0};
    BYTE output[sizeof(expected)];

    if (!winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT))
        return 1;

    WINPR_RC4_CTX *rc4 = winpr_RC4_New(key, sizeof(key));
    if (!rc4) {
        fputs("WinPR RC4 is unavailable without the OpenSSL legacy provider\n", stderr);
        return 1;
    }

    const BOOL updated = winpr_RC4_Update(rc4, sizeof(input), input, output);
    winpr_RC4_Free(rc4);
    if (!updated || memcmp(output, expected, sizeof(expected)) != 0) {
        fputs("WinPR RC4 output differs from the RFC 6229 vector\n", stderr);
        return 1;
    }
    return 0;
}
C

cc -I"$INSTALL_DIR/include/winpr3" "$WORK_DIR/test.c" \
    -L"$INSTALL_DIR/lib" -Wl,-rpath,"$INSTALL_DIR/lib" -lwinpr3 -o "$WORK_DIR/test"
OPENSSL_CONF=/dev/null OPENSSL_MODULES="$WORK_DIR/modules" "$WORK_DIR/test"
