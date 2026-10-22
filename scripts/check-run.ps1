param([Parameter(Mandatory = $true)][string]$Id)
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { 'G:\agy-work' }  # 工作目录，见本机配置
# agy 跑完后的机械核对：结果和被拒操作、沙盒外的工具调用、相对 .orig 的改动文件
$a = "$W\sandboxes\$Id"; $o = "$W\sandboxes\$Id.orig"
$results = Get-Content "$W\logs\$Id.log" -Encoding utf8 | Where-Object { $_ -match '"event":"result"' } | ForEach-Object {
    $line = $_
    try { ($line | ConvertFrom-Json -ErrorAction Stop).result }
    catch { if ($line -match '"conversation_id":"([0-9a-f-]{36})"') { [pscustomobject]@{ conversation_id = $Matches[1]; status = '(unparsed)' } } }
}
foreach ($r in $results) {
    "RESULT conv=$($r.conversation_id) status=$($r.status) secs=$([int]$r.duration_seconds) tokens=$($r.usage.total_tokens) denied=$(($r.denied_actions | ConvertTo-Json -Compress))"
}
$convs = $results | ForEach-Object { $_.conversation_id } | Select-Object -Unique
foreach ($c in $convs) {
    $tr = Join-Path $env:USERPROFILE ".gemini\antigravity-cli\brain\$c\.system_generated\logs\transcript.jsonl"
    if (-not (Test-Path $tr)) { continue }
    foreach ($s in (Get-Content $tr -Encoding utf8 | ConvertFrom-Json)) {
        if ($s.status -eq 'ERROR' -and $s.error) { "ERR  " + $s.error.Substring(0, [Math]::Min(200, $s.error.Length)) }
        foreach ($tc in @($s.tool_calls)) {
            if (-not $tc) { continue }
            if ($tc.name -eq 'run_command') { "RUN  " + $tc.args.CommandLine; continue }
            foreach ($prop in $tc.args.PSObject.Properties) {
                if ($prop.Name -notmatch '(?i)path|file|dir' -or $prop.Name -match '(?i)content') { continue }
                $p = ([string]$prop.Value).Trim('"') -replace '/', '\' -replace '\\\\', '\'
                if ($p -match '^[A-Za-z]:\\' -and $p -notlike "$a*") { "OUTSIDE $($tc.name) $($prop.Name)=$p" }
            }
        }
    }
}
Get-ChildItem $a -Recurse -File -Force | Where-Object { $_.FullName -notmatch '__pycache__|\\\.ruff_cache\\|\\\.pytest_cache\\|\\TASK\.md$|\\REPORT\.md$|\\AGENTS\.md$' } | ForEach-Object {
    $rel = $_.FullName.Substring($a.Length); $of = "$o$rel"
    if (-not (Test-Path $of)) { "NEW  $rel" } elseif ((Get-FileHash $_.FullName).Hash -ne (Get-FileHash $of).Hash) { "MOD  $rel" }
}
Get-ChildItem $o -Recurse -File -Force | Where-Object { $_.FullName -notmatch '__pycache__' } | ForEach-Object { $rel = $_.FullName.Substring($o.Length); if (-not (Test-Path "$a$rel")) { "DEL  $rel" } }
"REPORT=$(Test-Path "$a\REPORT.md")"
