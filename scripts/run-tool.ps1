param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Exe,
    [string[]]$ToolArgs = @(),
    [string]$PromptFile = '',
    [string]$FollowUp = '',
    [int]$TimeoutSec = 2400
)
# 在沙盒里运行一次外部执行工具：派单复制成 TASK.md，TEMP 指到沙盒 tmp；输出写进 logs\<Id>.log
# -ToolArgs 的每一项会原样作为一个参数传给工具；参数里不要放双引号（Windows PowerShell 5.1 调外部程序时会吃掉内嵌双引号），长内容放进 TASK.md
$ErrorActionPreference = 'Stop'
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { throw 'no work root: set TIAOKONG_WORKROOT or add it to the local config' }  # 工作目录，见本机配置
$W = [IO.Path]::GetFullPath($W)
if ($W -match '^[A-Za-z]:\\$') { throw "work root must not be a drive root: $W" }
if (-not (Test-Path "$W\.tiaokong-workdir")) { throw "missing .tiaokong-workdir in $W; run new-sandbox.ps1 first to create it" }
# 校验 -Id：只允许字母、数字、-、_、.，不能是 . 或 ..，不含分隔符和 :
if ($Id -notmatch '^[A-Za-z0-9._-]+$' -or $Id -eq '.' -or $Id -eq '..' -or $Id -match '[\\/:*?"<>|]') { throw "invalid Id: $Id" }
$sandbox = "$W\sandboxes\$Id"
if (-not (Test-Path $sandbox)) { throw "sandbox not found: $sandbox" }
if (-not $PromptFile) { $PromptFile = "$W\dispatch\$Id.md" }
if (-not (Test-Path $PromptFile)) { throw "prompt file not found: $PromptFile" }
New-Item -ItemType Directory -Force "$W\logs" | Out-Null
$log = "$W\logs\$Id.log"
$tmp = "$W\tmp\$Id"
New-Item -ItemType Directory -Force $tmp | Out-Null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$savedTEMP = $env:TEMP
$savedTMP = $env:TMP
$code = 0
$timeout = $false
try {
    $env:TEMP = $tmp
    $env:TMP = $tmp
    # PowerShell 5.1 会把参数里的双引号拆错，所以派单放进 TASK.md
    Copy-Item $PromptFile "$sandbox\TASK.md" -Force
    $p = 'Read the rules file and TASK.md in the current directory, then carry out TASK.md exactly. Write REPORT.md as TASK.md says. Reply in Chinese.'
    if ($FollowUp) { $p = $FollowUp }
    $args2 = @()
    foreach ($a in $ToolArgs) { $args2 += [string]$a.Replace('{PROMPT}', $p) }

    $inner = Join-Path $PSScriptRoot 'run-tool-inner.ps1'
    $spec = "$tmp\run-spec.json"
    $specObj = @{
        exe = $Exe
        args = $args2
        cwd = $sandbox
        log = $log
    }
    [IO.File]::WriteAllText($spec, ($specObj | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))

    Push-Location $sandbox
    try {
        Add-Content $log "===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') start tool=$Exe" -Encoding utf8
        $argString = '-NoProfile -ExecutionPolicy Bypass -File "' + $inner + '" -Spec "' + $spec + '"'
        try {
            $proc = Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $argString -WorkingDirectory $sandbox -NoNewWindow -PassThru
        } catch {
            Add-Content $log "===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') failed $($_.Exception.Message)" -Encoding utf8
            throw
        }
        if (-not $proc) {
            Add-Content $log "===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') failed Start-Process returned no process" -Encoding utf8
            throw "Start-Process returned no process"
        }
        $handle = $proc.Handle  # PowerShell 5.1 需要读一次 Handle 才能拿到 ExitCode
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
                $timeout = $true
                Add-Content $log "===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') timeout" -Encoding utf8
                taskkill /PID $proc.Id /T /F | Out-Null
                $proc.WaitForExit()
                $code = 124
                break
            }
            Start-Sleep -Milliseconds 200
        }
        if (-not $timeout) { $code = $proc.ExitCode }
        Add-Content $log "===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') exit=$code" -Encoding utf8
    } finally {
        Pop-Location
    }
} finally {
    $env:TEMP = $savedTEMP
    $env:TMP = $savedTMP
}
"exit=$code"
