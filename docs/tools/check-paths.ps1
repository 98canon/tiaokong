# Maintenance check for the skill repo. Run from anywhere:
#   powershell -NoProfile -ExecutionPolicy Bypass -File docs/tools/check-paths.ps1
# 1. Every repo path written in backticks in tracked Markdown exists.
# 2. Markdown is UTF-8 without BOM and LF; .ps1 is UTF-8 with BOM.
# 3. No old Chinese path names are left (files that list old names on purpose are skipped).
# Prints only problems and a summary line. Exit code 1 when anything is wrong.

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $root

$files = @(git -c core.quotepath=false ls-files) + @(git -c core.quotepath=false ls-files --others --exclude-standard)
$files = $files | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique

# Files that mention old names on purpose
$keepOld = @('CHANGELOG.md', 'docs/path-map.md', 'docs/tools/check-paths.ps1')
$keepOldPrefix = @('docs/basis/', 'docs/archive/', 'docs/plans/')
# Old names a file may mention on purpose: @{ 'path' = @('name', ...) }
$allow = @{}

$oldNames = @('规则/', '规则\', '调控师-本机', '调控师-登记', '调控师-项目', '调控师-模型记录', '调控师-work', '@调控师', 'skills/调控师', 'skills\调控师',
  '预置方案', '说明.md', '依据/', '待合入.md', '_archive/优化方案', '写入权.lock', '项目档案.md',
  'templates/派单', 'templates/登记', 'templates/本机配置', 'templates/模型记录', 'templates/阶段表', 'templates/沙盒规则',
  'templates\派单', 'templates\沙盒规则', '子代理通用守则.md', '审查标准.md')

$pathRe = '^(rules|templates|references|scripts|steps|docs)[/\\][^\s<>*`]*$'
$problems = New-Object System.Collections.Generic.List[string]

foreach ($f in $files) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $root $f))
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $hasCr = [Array]::IndexOf($bytes, [byte]13) -ge 0
    if ($f -like '*.md') {
        if ($hasBom) { $problems.Add("$f : has BOM") }
        if ($hasCr) { $problems.Add("$f : has CR") }
    } elseif ($f -like '*.ps1') {
        if (-not $hasBom) { $problems.Add("$f : .ps1 without BOM") }
    } else { continue }

    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $skip = ($keepOld -contains $f) -or ($keepOldPrefix | Where-Object { $f.StartsWith($_) })

    if ($f -like '*.md' -and -not $skip) {
        foreach ($m in [regex]::Matches($text, '`([^`\r\n]+)`')) {
            $p = $m.Groups[1].Value.Trim().TrimEnd('.', ',', '，', '。')
            if ($p -notmatch $pathRe) { continue }
            $rel = $p.Replace('\', '/')
            if (-not (Test-Path -LiteralPath (Join-Path $root $rel))) { $problems.Add("$f : missing path $p") }
        }
    }
    if (-not $skip) {
        foreach ($o in $oldNames) {
            if ($allow.ContainsKey($f) -and $allow[$f] -contains $o) { continue }
            if ($text.Contains($o)) { $problems.Add("$f : old name $o") }
        }
    }
}

$problems | Sort-Object -Unique | ForEach-Object { $_ }
"checked $($files.Count) files, $($problems.Count) problems"
if ($problems.Count) { exit 1 }
