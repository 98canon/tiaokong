# Live monitor for agy dispatches: follows every G:\agy-work\logs\*.log and prints one readable line per event.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.config\opencode\skills\调控师\scripts\watch-agy.ps1"     (Ctrl+C to stop)
param([string]$LogDir = '', [int]$FromEndLines = 5)
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { throw 'no work root: set TIAOKONG_WORKROOT or add it to the local config' }  # 工作目录，见本机配置
if (-not $LogDir) { $LogDir = "$W\logs" }
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$pos = @{}
$utf8 = New-Object Text.UTF8Encoding $false

function Show([string]$id, [string]$line) {
    $t = Get-Date -Format 'HH:mm:ss'
    if ($line.StartsWith('=====')) { Write-Host "[$t] [$id] $line" -ForegroundColor Cyan; return }
    try { $j = $line | ConvertFrom-Json -ErrorAction Stop } catch { if ($line.Trim()) { Write-Host "[$t] [$id] $line" -ForegroundColor DarkGray }; return }
    if ($j.event -eq 'result') {
        $r = $j.result
        $denied = if ($r.denied_actions) { ' DENIED=' + (($r.denied_actions | ForEach-Object { $_.display_name }) -join ',') } else { '' }
        Write-Host "[$t] [$id] RESULT status=$($r.status) $([int]$r.duration_seconds)s tokens=$($r.usage.total_tokens)$denied" -ForegroundColor Green
        return
    }
    $s = $j.step_update
    if (-not $s) { return }
    if (($s.state -eq 'ACTIVE') -and ($s.step_type -ne 'tool')) { return }
    if ($s.step_type -eq 'tool' -and $s.state -eq 'ACTIVE') {
        $p = $s.tool_info.parameters
        $arg = if ($p.CommandLine) { $p.CommandLine } elseif ($p.Path) { $p.Path } elseif ($p.AbsolutePath) { $p.AbsolutePath } elseif ($p.TargetFile) { $p.TargetFile } else { ($p | ConvertTo-Json -Compress) }
        $color = if ($s.tool_name -eq 'run_command') { 'Yellow' } elseif ($s.tool_name -match 'edit|write') { 'Magenta' } else { 'Gray' }
        Write-Host "[$t] [$id] #$($s.step_index) $($s.tool_name) $arg" -ForegroundColor $color
    } elseif ($s.state -eq 'ERROR') {
        Write-Host "[$t] [$id] #$($s.step_index) ERROR $($s.tool_name)" -ForegroundColor Red
    }
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
        if ($f.Length -le $pos[$f.FullName]) { continue }
        $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $fs.Seek($pos[$f.FullName], 'Begin') | Out-Null
            $buf = New-Object byte[] ($f.Length - $pos[$f.FullName])
            $n = $fs.Read($buf, 0, $buf.Length)
            $pos[$f.FullName] += $n
        } finally { $fs.Close() }
        foreach ($l in ($utf8.GetString($buf, 0, $n) -split "`r?`n")) { if ($l) { Show $id $l } }
    }
    $running = @(Get-CimInstance Win32_Process -Filter "Name='agy.exe'" | Where-Object { [string]$_.CommandLine -match ' -p ' }).Count
    $host.UI.RawUI.WindowTitle = "agy monitor - running: $running"
    Start-Sleep -Seconds 2
}
