param([string]$Id, [string]$Line)
$t = Get-Date -Format 'HH:mm:ss'
if ($Line.StartsWith('=====')) { Write-Host "[$t] [$Id] $Line" -ForegroundColor Cyan; return }
try { $j = $Line | ConvertFrom-Json -ErrorAction Stop } catch { if ($Line.Trim()) { Write-Host "[$t] [$Id] $Line" -ForegroundColor DarkGray }; return }
if ($j.event -eq 'result') {
    $r = $j.result
    $denied = if ($r.denied_actions) { ' DENIED=' + (($r.denied_actions | ForEach-Object { $_.display_name }) -join ',') } else { '' }
    Write-Host "[$t] [$Id] RESULT status=$($r.status) $([int]$r.duration_seconds)s tokens=$($r.usage.total_tokens)$denied" -ForegroundColor Green
    return
}
$s = $j.step_update
if (-not $s) { return }
if (($s.state -eq 'ACTIVE') -and ($s.step_type -ne 'tool')) { return }
if ($s.step_type -eq 'tool' -and $s.state -eq 'ACTIVE') {
    $p = $s.tool_info.parameters
    $arg = if ($p.CommandLine) { $p.CommandLine } elseif ($p.Path) { $p.Path } elseif ($p.AbsolutePath) { $p.AbsolutePath } elseif ($p.TargetFile) { $p.TargetFile } else { ($p | ConvertTo-Json -Compress) }
    $color = if ($s.tool_name -eq 'run_command') { 'Yellow' } elseif ($s.tool_name -match 'edit|write') { 'Magenta' } else { 'Gray' }
    Write-Host "[$t] [$Id] #$($s.step_index) $($s.tool_name) $arg" -ForegroundColor $color
} elseif ($s.state -eq 'ERROR') {
    Write-Host "[$t] [$Id] #$($s.step_index) ERROR $($s.tool_name)" -ForegroundColor Red
}
