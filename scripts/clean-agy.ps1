param([string]$ArchiveDir = '')
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { throw 'no work root: set TIAOKONG_WORKROOT or add it to the local config' }  # 工作目录，见本机配置
# 一轮 agy 任务结束后的清理：按 G:\agy-work\logs 里记下的 conversation_id 删 agy 的会话残留，
# 删任务启动前后 5 秒内新建的 agy 日志、崩溃和隐式记录，删 last_conversations.json 里沙盒路径的项，
# 清空沙盒和临时目录。日志移到 -ArchiveDir（不给就移到 G:\agy-work\logs\_done\<时间>）。
# 不动用户自己的会话、共享数据、配置和 agy 程序。
$logs = Get-ChildItem "$W\logs" -Filter *.log -File -ErrorAction SilentlyContinue
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
$extra | Remove-Item -Force -ErrorAction SilentlyContinue
$lc = "$cli\cache\last_conversations.json"
if (Test-Path $lc) {
    $j = Get-Content $lc -Raw | ConvertFrom-Json
    foreach ($p in @($j.PSObject.Properties | Where-Object { $_.Name -like "$W\sandboxes\*" })) { $j.PSObject.Properties.Remove($p.Name) }
    [IO.File]::WriteAllText($lc, ($j | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}
Remove-Item "$W\sandboxes\*", "$W\tmp\*" -Recurse -Force -ErrorAction SilentlyContinue
if (-not $ArchiveDir) { $ArchiveDir = "$W\logs\_done\$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
if ($logs) { New-Item -ItemType Directory -Force $ArchiveDir | Out-Null; $logs | Move-Item -Destination $ArchiveDir -Force }
$left = @(Get-ChildItem (Join-Path $env:USERPROFILE '.gemini') -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $nm = $_.Name; @($convs | Where-Object { $nm -like "*$_*" }).Count -gt 0 })
"convs=$($convs.Count) removed=$n extra=$($extra.Count) residue=$($left.Count) logs->$ArchiveDir"
