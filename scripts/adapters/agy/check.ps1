param([Parameter(Mandatory = $true)][string]$Id)
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { throw 'no work root: set TIAOKONG_WORKROOT or add it to the local config' }  # 工作目录，见本机配置
$W = [IO.Path]::GetFullPath($W)
if ($W -match '^[A-Za-z]:\\$') { throw "work root must not be a drive root: $W" }
if (-not (Test-Path "$W\.tiaokong-workdir")) { throw "missing .tiaokong-workdir in $W; run new-sandbox.ps1 first to create it" }
if ($Id -notmatch '^[A-Za-z0-9._-]+$' -or $Id -eq '.' -or $Id -eq '..' -or $Id -match '[\\/:*?"<>|]') { throw "invalid Id: $Id" }
# agy 适配核对：解析日志里的 result 事件和 transcript，报 RESULT/ERR/RUN/OUTSIDE
$a = "$W\sandboxes\$Id"
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
                $raw = ([string]$prop.Value).Trim('"')
                # 原始字符串是 UNC 或 // 开头，直接算外部
                if ($raw -match '^\\\\' -or $raw -match '^//') { "OUTSIDE $($tc.name) $($prop.Name)=$raw"; continue }
                # 不是绝对路径的，先和沙盒目录拼起来再规范化
                if ($raw -notmatch '^[A-Za-z]:') {
                    $raw = Join-Path $a $raw
                }
                try {
                    $pFull = [IO.Path]::GetFullPath($raw)
                } catch {
                    "OUTSIDE $($tc.name) $($prop.Name)=$raw (invalid path)"
                    continue
                }
                if (-not $pFull.StartsWith($a + '\', [StringComparison]::OrdinalIgnoreCase)) { "OUTSIDE $($tc.name) $($prop.Name)=$pFull" }
            }
        }
    }
}
