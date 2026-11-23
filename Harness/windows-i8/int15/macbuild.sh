#!/usr/bin/env bash
# macbuild.sh <tree dir name under Mac work dir> [extra swift flags...]: build harness release on the Mac, holding the shared swift lock.
source ~/.cache/int15-win-184c94d7/env.sh
tree=$1; shift; extra="$*"
ssh -o BatchMode=yes $MAC "set -euo pipefail; export PATH=\$HOME/.cargo/bin:/opt/homebrew/bin:\$PATH; M=\$HOME/$I8_MAC_DIR
  lock=\$HOME/xcode-work/.swift.lock
  for _ in \$(seq 1 160); do shlock -f \"\$lock\" -p \$\$ && break; sleep 15; done
  [[ \"\$(cat \"\$lock\" 2>/dev/null)\" == \$\$ ]] || { echo 'lock occupied' >&2; exit 1; }
  trap '[[ \"\$(cat \"\$lock\" 2>/dev/null)\" == \$\$ ]] && rm -f \"\$lock\"' EXIT
  mkdir -p \$M/btmp; export TMPDIR=\$M/btmp
  cd \$M/$tree
  date '+start %H:%M:%S'
  [[ -f Vendor/FreeRDP/install/lib/libfreerdp3.dylib ]] || bash Scripts/build-freerdp.sh > \$M/$tree-freerdp-build.log 2>&1
  date '+freerdp %H:%M:%S'
  [[ -f Vendor/IronRDP/install/lib/libcndf_ironrdp.a ]] || bash Scripts/build-ironrdp.sh --features legacy-tls > \$M/$tree-ironrdp-build.log 2>&1
  date '+ironrdp %H:%M:%S'
  swift build -c release --product rdp-engine-harness -Xswiftc -enable-testing $extra 2>&1 | tail -5
  date '+swift %H:%M:%S'"
