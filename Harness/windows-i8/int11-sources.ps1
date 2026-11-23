# int-11 Windows sources (run once through `run-i8.sh ps < int11-sources.ps1` after setup).
# gw1A / gw1B: 40 files of 64 KiB, same names, every file its own byte pattern (G-W1); gw1C: g00..g39, other names.
# gw6: 300 empty folders e000..e299 and 300 folders d000..d299 with one 1 KiB file (G-W6).
# zero.bin (0 B, G-W5), m7.bin (8 MiB, M7), big2.bin (a 1 GiB copy for M6 delete).
$ErrorActionPreference = 'Stop'
function Pattern([string]$path, [int]$seed) {
  $buf = New-Object byte[] (64KB)
  for ($i = 0; $i -lt $buf.Length; $i++) { $buf[$i] = [byte](($seed * 31 + $i * 7 + [math]::Floor($i / 256) * $seed) % 251) }
  [IO.File]::WriteAllBytes($path, $buf)
}
New-Item -ItemType Directory -Force C:\i8\src\gw1A, C:\i8\src\gw1B, C:\i8\src\gw1C, C:\i8\src\gw6 | Out-Null
for ($k = 0; $k -lt 40; $k++) {
  Pattern ("C:\i8\src\gw1A\f{0:00}.bin" -f $k) (2 * $k + 1)
  Pattern ("C:\i8\src\gw1B\f{0:00}.bin" -f $k) (2 * $k + 2)
  Pattern ("C:\i8\src\gw1C\g{0:00}.bin" -f $k) (200 + $k)
}
$kb = New-Object byte[] 1024; (New-Object Random 11).NextBytes($kb)
for ($k = 0; $k -lt 300; $k++) {
  New-Item -ItemType Directory -Force ("C:\i8\src\gw6\e{0:000}" -f $k) | Out-Null
  $d = "C:\i8\src\gw6\d{0:000}" -f $k
  New-Item -ItemType Directory -Force $d | Out-Null
  [IO.File]::WriteAllBytes("$d\one.bin", $kb)
}
[IO.File]::WriteAllBytes('C:\i8\src\zero.bin', (New-Object byte[] 0))
$m = New-Object byte[] (8MB); (New-Object Random 7).NextBytes($m); [IO.File]::WriteAllBytes('C:\i8\src\m7.bin', $m)
if (-not (Test-Path C:\i8\src\big2.bin)) { Copy-Item C:\i8\src\big.bin C:\i8\src\big2.bin }
'gw1A=' + (Get-ChildItem C:\i8\src\gw1A).Count + ' gw1B=' + (Get-ChildItem C:\i8\src\gw1B).Count + ' gw6=' + (Get-ChildItem C:\i8\src\gw6).Count
Get-ChildItem C:\i8\src\gw1A, C:\i8\src\gw1B, C:\i8\src\gw1C | ForEach-Object { 'sha ' + $_.Directory.Name + '\' + $_.Name + ' ' + (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLower() }
'freeGB=' + [math]::Round((Get-PSDrive C).Free / 1GB, 1)
