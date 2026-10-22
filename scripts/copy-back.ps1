param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string[]]$Allowed
)
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { 'G:\agy-work' }  # 工作目录，见本机配置
# 把审过的文件从沙盒拷回项目。只拷 -Allowed 列出的相对路径；项目里的文件在建沙盒后被改过就拒绝。
$ErrorActionPreference = 'Stop'
$a = "$W\sandboxes\$Id"; $o = "$W\sandboxes\$Id.orig"
foreach ($rel in $Allowed) {
    $rel = $rel.TrimStart('\')
    $s = "$a\$rel"; $orig = "$o\$rel"; $dst = Join-Path $Project $rel
    if (-not (Test-Path $s)) { throw "missing in sandbox: $rel" }
    if (Test-Path $orig) {
        if (-not (Test-Path $dst)) { throw "missing in project: $rel" }
        if ((Get-FileHash $dst).Hash -ne (Get-FileHash $orig).Hash) { throw "project file changed since sandbox was made: $rel" }
    } elseif (Test-Path $dst) { throw "new file already exists in project: $rel" }
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $s $dst -Force
    "copied $rel"
}
