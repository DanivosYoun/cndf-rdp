set -euo pipefail
S=$HOME/xcode-work/int15-win-184c94d7/src; mkdir -p $S; cd $S
mkdir -p "폴더M/하위/깊은" "폴더M/빈폴더" multi gw7/'x\' secret
printf 'root-한글-M.txt' > 폴더M/루트.txt; printf 'nested-한글-M' > 폴더M/하위/깊은/안쪽.txt
printf 'int8 small file 20B.' > multi/small.txt; printf 'mac-file-payload-한글 M' > multi/한글이름.txt
[[ -f multi/mid.bin ]] || head -c 6291456 /dev/urandom > multi/mid.bin
[[ -f big-m.bin ]] || head -c 1073741824 /dev/urandom > big-m.bin
printf 'x-f.t' > 'gw7/x\/f.txt'; printf 'a-b.tx' > 'gw7/a\b.txt'
mkdir -p small20; printf 'twenty-byte-file-ok.' > small20/s20.txt   # 20 bytes
# secret outside every selected folder
printf 'SECRET-184c94d7-do-not-transfer\n' > secret/secret.txt
# packages, parent P
P=pkg/P; rm -rf pkg; mkdir -p $P
mkdir -p $P/X.app/Contents/MacOS $P/X.app/Contents/Resources $P/X.app/Contents/Frameworks/Helper.app/Contents/MacOS
printf '<plist>X</plist>\n' > $P/X.app/Contents/Info.plist
head -c 70000 /dev/urandom > $P/X.app/Contents/MacOS/X; chmod +x $P/X.app/Contents/MacOS/X
printf 'res-한글\n' > "$P/X.app/Contents/Resources/표.txt"
printf '<plist>Helper</plist>\n' > $P/X.app/Contents/Frameworks/Helper.app/Contents/Info.plist
head -c 3000 /dev/urandom > $P/X.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper
ln -s ../../../../secret/secret.txt $P/X.app/Contents/Resources/inlink.txt   # link inside a package
mkdir -p $P/Note.rtfd; printf '{\\rtf1 note}' > $P/Note.rtfd/TXT.rtf; head -c 1234 /dev/urandom > $P/Note.rtfd/img.png
mkdir -p $P/Plug.bundle/Contents/MacOS; printf '<plist>Plug</plist>\n' > $P/Plug.bundle/Contents/Info.plist; head -c 500 /dev/urandom > $P/Plug.bundle/Contents/MacOS/Plug
mkdir -p $P/Proj.xcodeproj/project.xcworkspace; printf '// pbxproj\n' > $P/Proj.xcodeproj/project.pbxproj; printf '<ws/>\n' > $P/Proj.xcodeproj/project.xcworkspace/contents.xcworkspacedata
mkdir -p $P/rubyapp/.bundle; printf -- '---\nBUNDLE_PATH: "vendor"\n' > $P/rubyapp/.bundle/config; printf 'source "x"\n' > $P/rubyapp/Gemfile
mkdir -p $P/Empty.app
printf 'normal file in P\n' > $P/normal.txt
# links folder L
L=pkg/L; mkdir -p $L/node_modules/tool $L/node_modules/.bin $L/sub
printf 'ok file in L\n' > $L/ok.txt; printf 'sub file\n' > $L/sub/s.txt
printf '#!/usr/bin/env node\n' > $L/node_modules/tool/cli.js
ln -s ../tool/cli.js $L/node_modules/.bin/tool
ln -s ../../secret/secret.txt $L/secret-link.txt         # file link to outside secret
ln -s $S/secret $L/dirlink                               # directory link (absolute) outside
ln -s /nonexistent/i8-184c94d7 $L/broken                 # broken link
ln -s ../../secret/secret.txt pkg/rootlink.txt            # a selected root that is a link
# /tmp selection (parent path has the /tmp -> /private/tmp link)
T=/tmp/i8pkg-184c94d7; rm -rf $T; mkdir -p $T/T/inner; printf 'tmp file\n' > $T/T/inner/t.txt; printf 'tmp top\n' > $T/t1.txt
cd $S; find . -path ./big-m.bin -prune -o -type f -print0 | xargs -0 shasum -a 256 > sha.txt; shasum -a 256 big-m.bin >> sha.txt
cd $T; find . -type f -print0 | xargs -0 shasum -a 256 | sed 's#  \./#  tmp/#' >> $S/sha.txt
wc -l $S/sha.txt; ls -la $S/pkg/L
