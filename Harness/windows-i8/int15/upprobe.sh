#!/usr/bin/env bash
source ~/.cache/int15-win-184c94d7/env.sh; cd $W/fork
b64="$(base64 -w0 Harness/windows-i8/i8probe.ps1)"; i=0; T='C:\i8\i8probe.ps1'
printf 'if (Test-Path "%s.b64") { Remove-Item -Force "%s.b64" }\n' "$T" "$T" | $R ps
while [[ -n "${b64:i:1}" ]]; do printf 'Add-Content -NoNewline -Path "%s.b64" -Value "%s"\n' "$T" "${b64:i:2000}" | $R ps; i=$((i + 2000)); done
printf '[IO.File]::WriteAllBytes("%s", [Convert]::FromBase64String((Get-Content -Raw "%s.b64"))); Remove-Item "%s.b64"; (Get-FileHash -Algorithm SHA256 "%s").Hash.ToLower()\n' "$T" "$T" "$T" "$T" | $R ps
sha256sum Harness/windows-i8/i8probe.ps1 | cut -c1-64
