param([Parameter(Mandatory = $true)][string]$Spec)
# 由 run-tool.ps1 启动的内部脚本：在沙盒里执行工具，输出逐行实时写进主日志
$ErrorActionPreference = 'Stop'
$j = Get-Content $Spec -Raw | ConvertFrom-Json
Set-Location $j.cwd
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$cmd = Get-Command $j.exe -ErrorAction Stop
$argList = @()
foreach ($a in $j.args) { $argList += [string]$a }
& $cmd @argList 2>&1 | ForEach-Object { Add-Content -LiteralPath $j.log -Value ([string]$_) -Encoding utf8 }
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
exit $code
