param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string[]]$Allowed
)
$W = if ($env:TIAOKONG_WORKROOT) { $env:TIAOKONG_WORKROOT } else { throw 'no work root: set TIAOKONG_WORKROOT or add it to the local config' }  # 工作目录，见本机配置
$W = [IO.Path]::GetFullPath($W)
if ($W -match '^[A-Za-z]:\\$') { throw "work root must not be a drive root: $W" }
if (-not (Test-Path "$W\.tiaokong-workdir")) { throw "missing .tiaokong-workdir in $W; run new-sandbox.ps1 first to create it" }
if ($Id -notmatch '^[A-Za-z0-9._-]+$' -or $Id -eq '.' -or $Id -eq '..' -or $Id -match '[\\/:*?"<>|]') { throw "invalid Id: $Id" }
# 把审过的文件从沙盒拷回项目。只拷 -Allowed 列出的相对路径；项目里的文件在建沙盒后被改过就拒绝。
$ErrorActionPreference = 'Stop'
$a = "$W\sandboxes\$Id"; $o = "$W\sandboxes\$Id.orig"
$projFull = [IO.Path]::GetFullPath($Project)
$sandFull = [IO.Path]::GetFullPath($a)
foreach ($rel in $Allowed) {
    # 拒绝绝对路径、盘符和 ..
    if ($rel -match '^[A-Za-z]:' -or $rel -match '^/' -or $rel -match '^\\' -or $rel -match '\.\.' ) { throw "invalid allowed path: $rel" }
    $dst = Join-Path $projFull $rel
    $dstFull = [IO.Path]::GetFullPath($dst)
    if (-not $dstFull.StartsWith($projFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "allowed path escapes project: $rel" }
    $s = Join-Path $a $rel
    $sFull = [IO.Path]::GetFullPath($s)
    if (-not $sFull.StartsWith($sandFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "sandbox path escapes sandbox: $rel" }
    $orig = "$o\$rel"
    if (-not (Test-Path $sFull)) { throw "missing in sandbox: $rel" }
    if (Test-Path $orig) {
        if (-not (Test-Path $dstFull)) { throw "missing in project: $rel" }
        if ((Get-FileHash $dstFull).Hash -ne (Get-FileHash $orig).Hash) { throw "project file changed since sandbox was made: $rel" }
    } elseif (Test-Path $dstFull) { throw "new file already exists in project: $rel" }
    New-Item -ItemType Directory -Force (Split-Path $dstFull) | Out-Null
    Copy-Item $sFull $dstFull -Force
    "copied $rel"
}
