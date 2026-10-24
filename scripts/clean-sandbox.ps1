param([string]$ArchiveDir = '')
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { throw 'no work root: set TIAOKONG_WORKROOT or add it to the local config' }  # 工作目录，见本机配置
$W = [IO.Path]::GetFullPath($W)
if ($W -match '^[A-Za-z]:\\$') { throw "work root must not be a drive root: $W" }
if (-not (Test-Path "$W\.tiaokong-workdir")) { throw "missing .tiaokong-workdir in $W; run new-sandbox.ps1 first to create it" }
# 一轮任务结束后的通用清理：清空沙盒和临时目录，日志移到 -ArchiveDir（不给就移到 logs\_done\<时间>）。
# 不动用户自己的会话、共享数据、配置和外部工具程序。
$logs = Get-ChildItem "$W\logs" -Filter *.log -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.(out|err)\.log$' }
Remove-Item "$W\sandboxes\*", "$W\tmp\*" -Recurse -Force -ErrorAction SilentlyContinue
if (-not $ArchiveDir) { $ArchiveDir = "$W\logs\_done\$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
if ($logs) { New-Item -ItemType Directory -Force $ArchiveDir | Out-Null; $logs | Move-Item -Destination $ArchiveDir -Force }
"sandboxes=$(@(Get-ChildItem "$W\sandboxes" -ErrorAction SilentlyContinue).Count) tmp=$(@(Get-ChildItem "$W\tmp" -ErrorAction SilentlyContinue).Count) logs->$ArchiveDir"
