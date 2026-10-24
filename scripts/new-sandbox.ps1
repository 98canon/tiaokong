param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string[]]$Dirs,
    [string[]]$Files = @(),
    [string]$RulesFile = '',
    [string]$RulesName = 'AGENTS.md'
)
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { throw 'no work root: set TIAOKONG_WORKROOT or add it to the local config' }  # 工作目录，见本机配置
$W = [IO.Path]::GetFullPath($W)
if ($W -match '^[A-Za-z]:\\$') { throw "work root must not be a drive root: $W" }
# 第一次用某个工作根时，在 $W 下建标记文件 .tiaokong-workdir
if (-not (Test-Path "$W\.tiaokong-workdir")) {
    if (-not (Test-Path $W)) { New-Item -ItemType Directory -Force $W | Out-Null }
    $kids = @(Get-ChildItem $W -Force -ErrorAction SilentlyContinue)
    $allowed = @('sandboxes', 'tmp', 'dispatch', 'logs')
    if ($kids.Count -gt 0 -and @($kids | Where-Object { $allowed -notcontains $_.Name }).Count -gt 0) { throw "work root is not empty and has no .tiaokong-workdir; TIAOKONG_WORKROOT may be wrong: $W" }
    New-Item -ItemType File -Force "$W\.tiaokong-workdir" | Out-Null
}
# 校验 -Id 和 -RulesName：只允许字母、数字、-、_、.，不能是 . 或 ..，不含分隔符和 :
if ($Id -notmatch '^[A-Za-z0-9._-]+$' -or $Id -eq '.' -or $Id -eq '..' -or $Id -match '[\\/:*?"<>|]') { throw "invalid Id: $Id" }
if ($RulesName -notmatch '^[A-Za-z0-9._-]+$' -or $RulesName -eq '.' -or $RulesName -eq '..' -or $RulesName -match '[\\/:*?"<>|]') { throw "invalid RulesName: $RulesName" }
# 把项目的指定目录和文件复制到 sandboxes\<Id>，另存 <Id>.orig 作为改动前快照。
# 不复制 .env、真实数据、虚拟环境、.git：只复制 -Dirs 和 -Files 列出的内容。
# 规则文件 = 沙盒规则 + 子代理通用守则 + 项目规则文件（-RulesFile）
$ErrorActionPreference = 'Stop'
$dst = "$W\sandboxes\$Id"
if (Test-Path $dst) { throw "sandbox already exists: $dst" }
New-Item -ItemType Directory -Force $dst | Out-Null
foreach ($d in $Dirs) {
    robocopy (Join-Path $Project $d) (Join-Path $dst $d) /E /XD __pycache__ .pytest_cache .ruff_cache node_modules /NFL /NDL /NJH /NJS /NP | Out-Null
}
foreach ($f in $Files) {
    $s = Join-Path $Project $f
    if (Test-Path $s) { Copy-Item $s (Join-Path $dst $f) }
}
$utf8 = New-Object Text.UTF8Encoding $false
$agents = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\templates\沙盒规则.md'), [Text.Encoding]::UTF8)
$agents += "`n`n" + [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\规则\子代理通用守则.md'), [Text.Encoding]::UTF8)
if ($RulesFile) { $agents += "`n`n" + [IO.File]::ReadAllText($RulesFile, [Text.Encoding]::UTF8) }
[IO.File]::WriteAllText("$dst\$RulesName", $agents, $utf8)
robocopy $dst "$W\sandboxes\$Id.orig" /E /NFL /NDL /NJH /NJS /NP | Out-Null
New-Item -ItemType Directory -Force "$W\tmp\$Id" | Out-Null
"sandbox=$dst files=$((Get-ChildItem $dst -Recurse -File).Count)"
