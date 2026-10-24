param([Parameter(Mandatory = $true)][string]$Id)
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { throw 'no work root: set TIAOKONG_WORKROOT or add it to the local config' }  # 工作目录，见本机配置
$W = [IO.Path]::GetFullPath($W)
if ($W -match '^[A-Za-z]:\\$') { throw "work root must not be a drive root: $W" }
if (-not (Test-Path "$W\.tiaokong-workdir")) { throw "missing .tiaokong-workdir in $W; run new-sandbox.ps1 first to create it" }
if ($Id -notmatch '^[A-Za-z0-9._-]+$' -or $Id -eq '.' -or $Id -eq '..' -or $Id -match '[\\/:*?"<>|]') { throw "invalid Id: $Id" }
# 通用核对：相对 .orig 的改动文件、日志里最后一条 exit= 或 timeout、REPORT.md 是否存在
$a = "$W\sandboxes\$Id"; $o = "$W\sandboxes\$Id.orig"
$log = "$W\logs\$Id.log"
$last = Get-Content $log -Encoding utf8 -Tail 20 -ErrorAction SilentlyContinue | Where-Object { $_ -match '^===== .*(exit=|timeout)' } | Select-Object -Last 1
if ($last) { $last }
Get-ChildItem $a -Recurse -File -Force | Where-Object { $_.FullName -notmatch '__pycache__|\\\.ruff_cache\\|\\\.pytest_cache\\|\\TASK\.md$|\\REPORT\.md$|\\AGENTS\.md$|\\CLAUDE\.md$' } | ForEach-Object {
    $rel = $_.FullName.Substring($a.Length); $of = "$o$rel"
    if (-not (Test-Path $of)) { "NEW  $rel" } elseif ((Get-FileHash $_.FullName).Hash -ne (Get-FileHash $of).Hash) { "MOD  $rel" }
}
Get-ChildItem $o -Recurse -File -Force | Where-Object { $_.FullName -notmatch '__pycache__' } | ForEach-Object { $rel = $_.FullName.Substring($o.Length); if (-not (Test-Path "$a$rel")) { "DEL  $rel" } }
"REPORT=$(Test-Path "$a\REPORT.md")"
