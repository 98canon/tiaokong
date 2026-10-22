param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string[]]$Dirs,
    [string[]]$Files = @(),
    [string]$RulesFile = ''
)
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { 'G:\agy-work' }  # 工作目录，见本机配置
# 把项目的指定目录和文件复制到 G:\agy-work\sandboxes\<Id>，另存 <Id>.orig 作为改动前快照。
# 不复制 .env、真实数据、虚拟环境、.git：只复制 -Dirs 和 -Files 列出的内容。
# AGENTS.md = agy 沙盒规则 + 子代理通用守则 + 项目规则文件（-RulesFile）
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
$agents = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\templates\agy-AGENTS.md'), [Text.Encoding]::UTF8)
$agents += "`n`n" + [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\规则\子代理通用守则.md'), [Text.Encoding]::UTF8)
if ($RulesFile) { $agents += "`n`n" + [IO.File]::ReadAllText($RulesFile, [Text.Encoding]::UTF8) }
[IO.File]::WriteAllText("$dst\AGENTS.md", $agents, $utf8)
robocopy $dst "$W\sandboxes\$Id.orig" /E /NFL /NDL /NJH /NJS /NP | Out-Null
New-Item -ItemType Directory -Force "$W\tmp\$Id" | Out-Null
"sandbox=$dst files=$((Get-ChildItem $dst -Recurse -File).Count)"
