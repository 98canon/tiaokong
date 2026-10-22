param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Model,
    [string]$Effort = '',
    [string]$Conversation = '',
    [string]$PromptFile = '',
    [int]$TimeoutSec = 2400,
    [string]$FollowUp = ''
)
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { 'G:\agy-work' }  # 工作目录，见本机配置
# 在沙盒里运行一次 agy：派单复制成 TASK.md，-p 只传一句短英文；TEMP 指到 G 盘；输出写进 G:\agy-work\logs\<Id>.log
$sandbox = "$W\sandboxes\$Id"
if (-not $PromptFile) { $PromptFile = "$W\dispatch\$Id.md" }
New-Item -ItemType Directory -Force "$W\logs" | Out-Null
$log = "$W\logs\$Id.log"
$tmp = "$W\tmp\$Id"
New-Item -ItemType Directory -Force $tmp | Out-Null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:TEMP = $tmp
$env:TMP = $tmp
# PowerShell 5.1 会把参数里的双引号拆错，所以派单放进 TASK.md
Copy-Item $PromptFile "$sandbox\TASK.md" -Force
$p = 'Read AGENTS.md and TASK.md in the current directory, then carry out TASK.md exactly. Write REPORT.md as TASK.md says. Reply in Chinese.'
if ($Conversation) { $p = 'Read TASK.md in the current directory again (it has been updated) and carry it out exactly. Update REPORT.md. Reply in Chinese.' }
if ($FollowUp) { $p = $FollowUp }
$args2 = @('-p', $p, '--model', $Model, '--mode', 'accept-edits', '--output-format', 'stream-json', '--print-timeout', "${TimeoutSec}s")
if ($Effort) { $args2 += @('--effort', $Effort) }
if ($Conversation) { $args2 += @('--conversation', $Conversation) }
Push-Location $sandbox
try {
    Add-Content $log "===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') start model=$Model effort=$Effort conv=$Conversation" -Encoding utf8
    & "$env:LOCALAPPDATA\agy\bin\agy.exe" @args2 2>&1 | ForEach-Object { Add-Content $log ([string]$_) -Encoding utf8 }
    $code = $LASTEXITCODE
    Add-Content $log "===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') exit=$code" -Encoding utf8
} finally { Pop-Location }
"exit=$code"
