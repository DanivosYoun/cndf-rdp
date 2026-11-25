Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AcceptScreen {
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int v);
}
'@
[void][AcceptScreen]::SetProcessDpiAwarenessContext([IntPtr](-4))
$run=(Get-Content C:\i8\runid.txt -Raw)
$out="C:\i8\out\$run.server.log"
$old=''
$driveDone=$false
$driveSeed= '\\tsclient\Home\'+ (([string][char]0xd55c) + ([char]0xae00) + '-seed.txt')
$driveWrite= '\\tsclient\Home\'+ (([string][char]0xd55c) + ([char]0xae00) + '-write.txt')
for($i=0; $i -lt 3600; $i++){
    $size=([AcceptScreen]::GetSystemMetrics(0)).ToString()+'x'+[AcceptScreen]::GetSystemMetrics(1)
    if($size -ne $old) {
        "$(Get-Date -Format o) screen=$size" | Add-Content -LiteralPath $out -Encoding UTF8
        $old=$size
    }
    if(-not $driveDone -and (Test-Path -LiteralPath $driveSeed)){
        try {
            $seed=[IO.File]::ReadAllText($driveSeed)
            [IO.File]::WriteAllText($driveWrite, 'win-home-write', [Text.UTF8Encoding]::new($false))
            "$(Get-Date -Format o) tsclientHome=True seed=$seed wrote=$([IO.File]::ReadAllText($driveWrite))" | Add-Content -LiteralPath $out -Encoding UTF8
            $driveDone=$true
        } catch { }
    }
    Start-Sleep -Milliseconds 150
}
