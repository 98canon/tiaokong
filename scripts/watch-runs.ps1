# Live monitor for sandbox runs: follows every logs\*.log and prints one readable line per event.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File "<skill 目录>\scripts\watch-runs.ps1"     (Ctrl+C to stop)
param([string]$LogDir = '', [int]$FromEndLines = 5, [string]$Formatter = '', [string]$ProcessName = '')
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { throw 'no work root: set TIAOKONG_WORKROOT or add it to the local config' }  # 工作目录，见本机配置
$W = [IO.Path]::GetFullPath($W)
if ($W -match '^[A-Za-z]:\\$') { throw "work root must not be a drive root: $W" }
if (-not (Test-Path "$W\.tiaokong-workdir")) { throw "missing .tiaokong-workdir in $W; run new-sandbox.ps1 first to create it" }
if (-not $LogDir) { $LogDir = "$W\logs" }
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$pos = @{}
$utf8 = New-Object Text.UTF8Encoding $false

function Show([string]$id, [string]$line) {
    $t = Get-Date -Format 'HH:mm:ss'
    if ($Formatter) { & $Formatter -Id $id -Line $line; return }
    if ($line.StartsWith('=====')) { Write-Host "[$t] [$id] $line" -ForegroundColor Cyan; return }
    if ($line.Trim()) { Write-Host "[$t] [$id] $line" -ForegroundColor DarkGray }
}

Write-Host "watching $LogDir  (Ctrl+C to stop)" -ForegroundColor Cyan
while ($true) {
    foreach ($f in Get-ChildItem $LogDir -Filter *.log -ErrorAction SilentlyContinue) {
        $id = $f.BaseName
        if (-not $pos.ContainsKey($f.FullName)) {
            # first sight: show only the last few lines
            $lines = Get-Content $f.FullName -Encoding utf8 -Tail $FromEndLines
            foreach ($l in $lines) { Show $id $l }
            $pos[$f.FullName] = $f.Length
            continue
        }
        if ($f.Length -lt $pos[$f.FullName]) { $pos[$f.FullName] = 0 }
        if ($f.Length -le $pos[$f.FullName]) { continue }
        $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $fs.Seek($pos[$f.FullName], 'Begin') | Out-Null
            $buf = New-Object byte[] ($f.Length - $pos[$f.FullName])
            $n = $fs.Read($buf, 0, $buf.Length)
            $pos[$f.FullName] += $n
        } finally { $fs.Close() }
        # 只把最后一个换行之前的字节解码打印，剩下的半行留到下一轮，避免 UTF-8 被拆开
        $textBytes = $buf[0..($n-1)]
        $lastNl = -1
        for ($i = $n - 1; $i -ge 0; $i--) { if ($textBytes[$i] -eq 10) { $lastNl = $i; break } }
        if ($lastNl -lt 0) { continue }
        $good = $utf8.GetString($textBytes, 0, $lastNl)
        $pos[$f.FullName] -= ($n - $lastNl - 1)
        foreach ($l in ($good -split "`r?`n")) { if ($l) { Show $id $l } }
    }
    if ($ProcessName) {
        $running = @(Get-CimInstance Win32_Process -Filter "Name='$ProcessName'" -ErrorAction SilentlyContinue).Count
        $host.UI.RawUI.WindowTitle = "$ProcessName monitor - running: $running"
    }
    Start-Sleep -Seconds 2
}
