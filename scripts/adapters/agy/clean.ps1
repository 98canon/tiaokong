# 必须在 clean-sandbox.ps1 之前运行（它要读还没移走的日志）。
param([switch]$IncludeTimeWindow)
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { throw 'no work root: set TIAOKONG_WORKROOT or add it to the local config' }  # 工作目录，见本机配置
$W = [IO.Path]::GetFullPath($W)
if ($W -match '^[A-Za-z]:\\$') { throw "work root must not be a drive root: $W" }
if (-not (Test-Path "$W\.tiaokong-workdir")) { throw "missing .tiaokong-workdir in $W; run new-sandbox.ps1 first to create it" }
# agy 适配清理：按 logs 里记下的 conversation_id 删 agy 的会话残留，
# 删任务启动前后 5 秒内新建的 agy 日志、崩溃和隐式记录，删 last_conversations.json 里沙盒路径的项。
# 不动用户自己的会话、共享数据、配置和 agy 程序。
$logs = Get-ChildItem "$W\logs" -Filter *.log -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.(out|err)\.log$' }
$convs = @(); $starts = @()
foreach ($f in $logs) {
    $lines = Get-Content $f.FullName -Encoding utf8
    $convs += ($lines | Select-String -Pattern '"conversation_id":"([0-9a-f-]{36})"' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value })
    $starts += ($lines | Where-Object { $_ -match '^===== (\S+ \S+) start' } | ForEach-Object { [datetime]$Matches[1] })
}
$convs = @($convs | Sort-Object -Unique)
$cli = Join-Path $env:USERPROFILE '.gemini\antigravity-cli'
$n = 0
foreach ($c in $convs) {
    foreach ($t in "$cli\conversations\$c.db", "$cli\brain\$c", "$cli\annotations\$c.pbtxt", "$cli\presence\$c.lock") {
        if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath $t) { "LOCKED $t" } else { $n++ } }
    }
}
$extra = @(Get-ChildItem "$cli\log", "$cli\crashes", "$cli\implicit" -File -ErrorAction SilentlyContinue | Where-Object {
    $ct = $_.CreationTime; @($starts | Where-Object { [math]::Abs(($ct - $_).TotalSeconds) -le 5 }).Count -gt 0 })
if ($IncludeTimeWindow) {
    $extra | Remove-Item -Force -ErrorAction SilentlyContinue
} else {
    foreach ($e in $extra) { "CANDIDATE $($e.FullName)" }
}
$lc = "$cli\cache\last_conversations.json"
$lcChanged = $false
if (Test-Path $lc) {
    $j = Get-Content $lc -Raw | ConvertFrom-Json
    foreach ($p in @($j.PSObject.Properties | Where-Object { $_.Name -like "$W\sandboxes\*" })) { $j.PSObject.Properties.Remove($p.Name); $lcChanged = $true }
    if ($lcChanged) { [IO.File]::WriteAllText($lc, ($j | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false)) }
}
$left = @(Get-ChildItem (Join-Path $env:USERPROFILE '.gemini') -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $nm = $_.Name; @($convs | Where-Object { $nm -like "*$_*" }).Count -gt 0 })
"convs=$($convs.Count) removed=$n extra=$($extra.Count) residue=$($left.Count)"
