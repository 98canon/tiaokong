param(
    [string]$TempRoot = '',
    [string]$ControlRoot = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# Independent contract tests. Do not read the implementation or other test files.
$script:PassCount = 0
$script:FailCount = 0
$script:OwnDirectory = $null
$script:ActiveProcess = $null
$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:Utf8 = New-Object System.Text.UTF8Encoding($false, $true)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal([string]$Actual, [string]$Expected, [string]$Message) {
    if (-not [string]::Equals($Actual, $Expected, [StringComparison]::Ordinal)) {
        throw ($Message + ' expected=<' + $Expected + '> actual=<' + $Actual + '>')
    }
}

function Get-TestCommitHash {
    # Local, re-created on every call: never inherit a caller/loop variable named hash.
    $commitHashLiteral = '0123456789abcdef0123456789abcdef01234567'
    Assert-Equal ([string]$commitHashLiteral.Length) '40' 'fixture source hash must be exactly 40 characters'
    Assert-True ([regex]::IsMatch($commitHashLiteral, '\A[0-9a-f]{40}\z')) 'fixture source hash must be lowercase hexadecimal'
    return $commitHashLiteral
}

function Assert-Bytes([string]$File, [byte[]]$Expected) {
    Assert-True ([IO.File]::Exists($File)) 'original file disappeared'
    Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($File))) `
        ([Convert]::ToBase64String($Expected)) 'file bytes differ'
}

function Test-AbsolutePath([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    if ($Value -match '[\x00-\x1f<>"|?*]') { return $false }
    if ($Value -match '^[\\/]{2}[?.][\\/]') { return $false }
    if ($Value -match '^[A-Za-z]:[\\/]') {
        return ($Value.Substring(2).IndexOf(':') -lt 0)
    }
    return ($Value -match '^[\\/]{2}[^\\/:]+[\\/][^\\/:]+(?:[\\/][^:]*)?$')
}

function Assert-NoReparse([string]$Directory) {
    $current = New-Object IO.DirectoryInfo($Directory)
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'ControlRoot and its ancestors must not be reparse points'
        }
        $current = $current.Parent
    }
}

# Windows CommandLineToArgvW/CRT rules, including embedded quotes and trailing slashes.
function ConvertTo-WindowsArgument([AllowEmptyString()][string]$Value) {
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) { $slashes++; continue }
        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, (2 * $slashes + 1))
            [void]$builder.Append([char]34)
        } else {
            [void]$builder.Append([char]92, $slashes)
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    [void]$builder.Append([char]92, (2 * $slashes))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Stop-OwnedProcess([Diagnostics.Process]$Process) {
    if ($Process.HasExited) { return }
    # Only the PID returned by our Process.Start is ever a taskkill target.
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $info.Arguments = '/PID ' + $Process.Id + ' /T /F'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $script:Utf8
    $info.StandardErrorEncoding = $script:Utf8
    $killer = New-Object Diagnostics.Process
    $killer.StartInfo = $info
    try {
        [void]$killer.Start()
        $killOut = $killer.StandardOutput.ReadToEndAsync()
        $killErr = $killer.StandardError.ReadToEndAsync()
        if (-not $killer.WaitForExit(3000)) {
            $killer.Kill()
            [void]$killer.WaitForExit(1000)
        }
        [void]$killOut.Wait(1000)
        [void]$killErr.Wait(1000)
        if (-not $Process.WaitForExit(2000)) { throw 'owned process tree did not terminate' }
    } finally { $killer.Dispose() }
}

function Invoke-Control([string[]]$Parameters, [int]$ExpectedHashLength = 40) {
    # Zero is used only by deliberate invalid-Hash cases; their business usage remains asserted.
    $hashParameterIndex = [Array]::IndexOf($Parameters, '-Hash')
    if ($hashParameterIndex -ge 0 -and $ExpectedHashLength -gt 0) {
        Assert-True (($hashParameterIndex + 1) -lt $Parameters.Length) 'fixture hash argument has no value'
        $argumentHash = $Parameters[$hashParameterIndex + 1]
        Assert-Equal ([string]$argumentHash.Length) ([string]$ExpectedHashLength) 'fixture transmitted hash length'
        Assert-True ([regex]::IsMatch($argumentHash, '\A[0-9a-f]{7,40}\z')) 'fixture transmitted hash must satisfy the frozen 7-to-40 contract'
    }
    $remaining = 105000 - $script:Clock.ElapsedMilliseconds
    if ($remaining -le 0) { throw '120-second suite budget exhausted (cleanup reserved)' }
    if (-not [IO.File]::Exists($script:Target)) { throw 'test startup failure: stage-commit.ps1 missing' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:Target) + $Parameters
    $encoded = foreach ($argument in $arguments) { ConvertTo-WindowsArgument $argument }
    $info.Arguments = $encoded -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $script:CaseDirectory
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $script:Utf8
    $info.StandardErrorEncoding = $script:Utf8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $script:ActiveProcess = $process
    $started = $false
    try {
        if (-not $process.Start()) { throw 'test startup failure: Process.Start returned false' }
        $started = $true
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $timeout = [int][Math]::Min(30000, $remaining)
        if (-not $process.WaitForExit($timeout)) {
            Stop-OwnedProcess $process
            [void]$outTask.Wait(1000)
            [void]$errTask.Wait(1000)
            throw ('child timeout after ' + $timeout + 'ms')
        }
        if (-not $outTask.Wait(2000) -or -not $errTask.Wait(2000)) {
            throw 'redirected stream completion timeout'
        }
        return [pscustomobject]@{ Code = $process.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
    } finally {
        try {
            # Start failures have no PID; they are failures, never file-missing results.
            if ($started -and -not $process.HasExited) {
                Stop-OwnedProcess $process
            }
        } finally {
            $script:ActiveProcess = $null
            $process.Dispose()
        }
    }
}

function Get-Protocol([object]$Result, [int]$Code) {
    Assert-Equal ([string]$Result.Code) ([string]$Code) ('exit code; stdout=' + $Result.Out + '; stderr=' + $Result.Err)
    Assert-Equal $Result.Err '' 'stderr must be empty'
    $text = $Result.Out.Replace("`r`n", "`n")
    Assert-True (-not $text.Contains("`r")) 'bare CR in protocol'
    if ($text.EndsWith("`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 1) }
    return $text
}

function Assert-Protocol([object]$Result, [int]$Code, [string[]]$Lines) {
    Assert-Equal (Get-Protocol $Result $Code) ($Lines -join "`n") 'complete stdout protocol'
}

function Assert-Message([object]$Result, [string]$Status, [int]$Code) {
    $text = Get-Protocol $Result $Code
    $pattern = '\Astatus=' + [regex]::Escape($Status) + '\nmessage=[^\r\n]+\z'
    Assert-True ([regex]::IsMatch($text, $pattern)) ('complete message protocol invalid: ' + $text)
    if ($Status -eq 'usage') {
        Assert-True ([regex]::IsMatch($text.Split("`n")[1], '\Amessage=[\x20-\x7e]+\z')) 'usage message must be English'
    }
}

function Assert-NoResidue([string]$File) {
    $all = @([IO.Directory]::GetFileSystemEntries($script:CaseDirectory))
    if ([IO.File]::Exists($File)) {
        Assert-Equal ([string]$all.Count) '1' ('unexpected temporary entries: ' + ($all -join ', '))
        Assert-Equal $all[0] $File 'unexpected surviving entry'
    } else {
        Assert-Equal ([string]$all.Count) '0' ('unexpected temporary entries: ' + ($all -join ', '))
    }
}

function New-StageFile([string]$Text, [bool]$Bom = $false) {
    $file = Join-Path $script:CaseDirectory "阶段 [甲] O'Brien.md"
    $bytes = $script:Utf8.GetBytes($Text)
    if ($Bom) { $bytes = [byte[]](@(0xef, 0xbb, 0xbf) + $bytes) }
    [IO.File]::WriteAllBytes($file, $bytes)
    return $file
}

function Assert-TextBytes([string]$File, [string]$Text) {
    Assert-Bytes $File ($script:Utf8.GetBytes($Text))
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        if ($script:Clock.ElapsedMilliseconds -ge 105000) { throw 'suite budget exhausted (15 seconds reserved for cleanup)' }
        $script:CaseDirectory = Join-Path $script:OwnDirectory ([Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:CaseDirectory)
        & $Body
        $script:PassCount++
        Write-Output ('PASS ' + $Name)
    } catch {
        $script:FailCount++
        $message = $_.Exception.Message.Replace("`r", '\r').Replace("`n", '\n')
        Write-Output ('FAIL ' + $Name + ': ' + $message)
    }
}

function Assert-ListOutput([object]$Result, [string[]]$Entries) {
    $dash = [Math]::Min(5, $Entries.Count)
    $star = [Math]::Max(0, $Entries.Count - 5)
    $expected = @('status=ok', ('dash_count=' + $dash), ('star_count=' + $star))
    for ($index = 0; $index -lt $dash; $index++) { $expected += 'top=' + $Entries[$index] }
    Assert-Protocol $Result 0 $expected
}

try {
    if (-not (Test-AbsolutePath $TempRoot)) { throw 'TempRoot must be an absolute existing non-system-drive directory' }
    $TempRoot = [IO.Path]::GetFullPath($TempRoot)
    if (-not [IO.Directory]::Exists($TempRoot)) { throw 'TempRoot directory missing' }
    $systemRoot = [IO.Path]::GetPathRoot($env:SystemRoot)
    if ([string]::Equals([IO.Path]::GetPathRoot($TempRoot), $systemRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'TempRoot must not be on the system drive'
    }
    if ($ControlRoot.Length -gt 0) {
        if (-not (Test-AbsolutePath $ControlRoot)) { throw 'ControlRoot must be an absolute directory inside TempRoot' }
        $ControlRoot = [IO.Path]::GetFullPath($ControlRoot)
        $boundary = $TempRoot.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
        if (-not $ControlRoot.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'ControlRoot must be strictly inside TempRoot'
        }
        if (-not [IO.Directory]::Exists($ControlRoot)) { throw 'ControlRoot directory missing' }
        Assert-NoReparse $ControlRoot
    } else {
        $ControlRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\scripts\control'))
    }
    $script:Target = Join-Path $ControlRoot 'stage-commit.ps1'
} catch {
    Write-Output 'status=usage'
    Write-Output ('message=' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' '))
    exit 2
}

try {
    if (-not [IO.File]::Exists($script:Target)) { throw 'test startup failure: stage-commit.ps1 missing (not a business file-missing result)' }
    $script:OwnDirectory = Join-Path $TempRoot ("stage tests 中文 [甲] O'Brien " + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:OwnDirectory)
    $prefix = "# 阶段表`n`n| 阶段 | 状态 |`n| P1 | 进行中 |`n`n- 外部列表`n* 外部隐藏`n## 最近提交（不匹配标题）`n- 标题下的列表`n`n最近提交（第一节）`n`n`n"
    $suffix = "`n`n尾部正文  保留`t制表符`n- 尾部列表`n* 尾部隐藏`n最近提交（第二节）`n- 第二节条目`n* 第二节隐藏`n"
    $newLine = '- `' + (Get-TestCommitHash) + '` 新增记录'

    foreach ($count in @(0, 4, 5, 12)) {
        Test-Case ('add-count-' + $count) {
            $old = @(); $wanted = @($newLine)
            for ($index = 1; $index -le $count; $index++) {
                $old += '- 原提交 ' + $index
                $marker = if ($index -lt 5) { '- ' } else { '* ' }
                $wanted += $marker + '原提交 ' + $index
            }
            # For zero entries a terminating body begins immediately after leading blanks.
            $tail = if ($count -eq 0) { $suffix.Substring(2) } else { $suffix }
            $file = New-StageFile ($prefix + ($old -join "`n") + $tail)
            $result = Invoke-Control @('-Action', 'add', '-File', $file, '-Hash', (Get-TestCommitHash), '-Text', '新增记录')
            Assert-ListOutput $result $wanted
            $expectedTail = if ($count -eq 0) { "`n" + $tail } else { $tail }
            Assert-TextBytes $file ($prefix + ($wanted -join "`n") + $expectedTail)
            Assert-NoResidue $file
        }
    }

    Test-Case 'normalize-twelve-all-dashes-preserves-outside-first-section' {
        $old = @(); $wanted = @()
        for ($index = 1; $index -le 12; $index++) {
            $old += '- 旧正文 `' + $index + '`  中文  '
            $marker = if ($index -le 5) { '- ' } else { '* ' }
            $wanted += $marker + '旧正文 `' + $index + '`  中文  '
        }
        $file = New-StageFile ($prefix + ($old -join "`n") + $suffix)
        $result = Invoke-Control @('-Action', 'normalize', '-File', $file)
        Assert-ListOutput $result $wanted
        Assert-TextBytes $file ($prefix + ($wanted -join "`n") + $suffix)
        Assert-NoResidue $file
    }

    foreach ($count in @(0, 4, 5, 12)) {
        Test-Case ('check-ok-count-' + $count + '-read-only-bom-crlf') {
            $entries = @()
            for ($index = 1; $index -le $count; $index++) {
                $marker = if ($index -le 5) { '- ' } else { '* ' }
                $entries += $marker + '记录' + $index
            }
            $tail = if ($count -eq 0) { $suffix.Substring(2) } else { $suffix }
            $file = New-StageFile (($prefix + ($entries -join "`n") + $tail).Replace("`n", "`r`n")) $true
            $before = [IO.File]::ReadAllBytes($file)
            $result = Invoke-Control @('-Action', 'check', '-File', $file)
            Assert-Protocol $result 0 @('status=ok', ('dash_count=' + [Math]::Min(5, $count)), ('star_count=' + [Math]::Max(0, $count - 5)))
            Assert-Bytes $file $before
            Assert-NoResidue $file
        }
    }

    foreach ($style in @('twelve-dashes', 'four-stars', 'wrong-order')) {
        Test-Case ('check-bad-' + $style + '-read-only') {
            $entries = @(); $dash = 0; $star = 0
            if ($style -eq 'twelve-dashes') { $entries = @(1..12 | ForEach-Object { '- 条目' + $_ }); $dash = 12 }
            if ($style -eq 'four-stars') { $entries = @(1..4 | ForEach-Object { '* 条目' + $_ }); $star = 4 }
            if ($style -eq 'wrong-order') { $entries = @('* 第一', '- 第二', '- 第三', '- 第四', '- 第五', '- 第六'); $dash = 5; $star = 1 }
            $file = New-StageFile (($prefix + ($entries -join "`n") + $suffix).Replace("`n", "`r`n")) $true
            $before = [IO.File]::ReadAllBytes($file)
            Assert-Protocol (Invoke-Control @('-Action', 'check', '-File', $file)) 1 @('status=bad', ('dash_count=' + $dash), ('star_count=' + $star))
            Assert-Bytes $file $before
            Assert-NoResidue $file
        }
    }

    foreach ($ending in @('lf-final', 'lf-no-final', 'crlf-final', 'crlf-no-final', 'bom-crlf-no-final')) {
        Test-Case ('normalize-ending-' + $ending) {
            $text = "外部内容  `n`n最近提交`n`n* 一`n- 二`n* 三`n- 四`n* 五`n- 六`n`n尾部  `n"
            $expected = "外部内容  `n`n最近提交`n`n- 一`n- 二`n- 三`n- 四`n- 五`n* 六`n`n尾部  `n"
            if ($ending.Contains('no-final')) { $text = $text.TrimEnd([char]10); $expected = $expected.TrimEnd([char]10) }
            if ($ending.Contains('crlf')) { $text = $text.Replace("`n", "`r`n") }
            $file = New-StageFile $text ($ending.StartsWith('bom'))
            $result = Invoke-Control @('-Action', 'normalize', '-File', $file)
            Assert-ListOutput $result @('- 一', '- 二', '- 三', '- 四', '- 五', '* 六')
            Assert-TextBytes $file $expected
            Assert-NoResidue $file
        }
    }

    foreach ($ending in @('lf-final', 'lf-no-final', 'bom-crlf-final', 'bom-crlf-no-final')) {
        Test-Case ('add-at-eof-' + $ending) {
            $text = "前文`n最近提交`n`n- 已有"
            $expected = "前文`n最近提交`n`n" + $newLine + "`n- 已有"
            if (-not $ending.Contains('no-final')) { $text += "`n"; $expected += "`n" }
            if ($ending.Contains('crlf')) { $text = $text.Replace("`n", "`r`n") }
            $file = New-StageFile $text ($ending.StartsWith('bom'))
            Assert-ListOutput (Invoke-Control @('-Action', 'add', '-File', $file, '-Hash', (Get-TestCommitHash), '-Text', '新增记录')) @($newLine, '- 已有')
            Assert-TextBytes $file $expected
            Assert-NoResidue $file
        }
    }

    foreach ($barrier in @(' ', "`t", '正文停止', '## 下一节', '-不是列表', '*不是列表')) {
        Test-Case ('list-stops-at-' + ($barrier.Replace("`t", 'TAB'))) {
            $text = "最近提交`n`n* 第一`n" + $barrier + "`n- 不能并入`n* 不能改写`n"
            $expected = "最近提交`n`n- 第一`n" + $barrier + "`n- 不能并入`n* 不能改写`n"
            $file = New-StageFile $text
            Assert-ListOutput (Invoke-Control @('-Action', 'normalize', '-File', $file)) @('- 第一')
            Assert-TextBytes $file $expected
            Assert-NoResidue $file
        }
    }

    Test-Case 'blank-line-terminates-started-list' {
        $file = New-StageFile "最近提交`n`n`n* 第一`n`n* 不属于列表`n- 不属于列表`n"
        Assert-ListOutput (Invoke-Control @('-Action', 'normalize', '-File', $file)) @('- 第一')
        Assert-TextBytes $file "最近提交`n`n`n- 第一`n`n* 不属于列表`n- 不属于列表`n"
        Assert-NoResidue $file
    }

    Test-Case 'normalize-idempotent-preserves-outside-characters' {
        $text = "前文内嵌`r字符  `t保留`n`n最近提交`n`n- 一  `n- 二`t`n`n尾部内嵌`r字符`n`n"
        $file = New-StageFile $text
        Assert-ListOutput (Invoke-Control @('-Action', 'normalize', '-File', $file)) @('- 一  ', "- 二`t")
        Assert-TextBytes $file $text
        Assert-NoResidue $file
    }

    Test-Case 'empty-file-has-no-section-without-write' {
        $file = New-StageFile ''
        Assert-Protocol (Invoke-Control @('-Action', 'normalize', '-File', $file)) 1 @('status=no-commit-section')
        Assert-TextBytes $file ''
        Assert-NoResidue $file
    }

    Test-Case 'whitespace-is-not-leading-blank-empty-list' {
        $file = New-StageFile "最近提交`n`n `n* 后方不是提交`n"
        Assert-ListOutput (Invoke-Control @('-Action', 'add', '-File', $file, '-Hash', (Get-TestCommitHash), '-Text', '新增记录')) @($newLine)
        Assert-TextBytes $file ("最近提交`n`n" + $newLine + "`n `n* 后方不是提交`n")
        Assert-NoResidue $file
    }

    foreach ($hashFixture in @(
        @{ Value = '0123abc'; ExpectedLength = 7 },
        @{ Value = (Get-TestCommitHash); ExpectedLength = 40 }
    )) {
        Test-Case ('hash-boundary-backtick-and-text-roundtrip-' + $hashFixture.ExpectedLength) {
            $boundaryHash = [string]$hashFixture.Value
            Assert-Equal ([string]$boundaryHash.Length) ([string]$hashFixture.ExpectedLength) 'boundary fixture source hash length'
            $textValue = '  中文 "双引号" `反引号` = [方括号] O''Brien \"尾部引号" 尾反斜线\'
            $file = New-StageFile "最近提交`n- 旧条目`n"
            $line = '- `' + $boundaryHash + '` ' + $textValue
            Assert-ListOutput (Invoke-Control @('-Action', 'add', '-File', $file, '-Hash', $boundaryHash, '-Text', $textValue) -ExpectedHashLength $hashFixture.ExpectedLength) @($line, '- 旧条目')
            Assert-TextBytes $file ("最近提交`n" + $line + "`n- 旧条目`n")
            Assert-NoResidue $file
        }
    }

    $invalidAdds = @(
        @{ Name = 'hash-six'; Values = @('-Hash', 'abcdef', '-Text', '正文') },
        @{ Name = 'hash-forty-one'; Values = @('-Hash', ('a' * 41), '-Text', '正文') },
        @{ Name = 'hash-uppercase'; Values = @('-Hash', 'ABCDEF0', '-Text', '正文') },
        @{ Name = 'hash-nonhex'; Values = @('-Hash', 'abcdefg', '-Text', '正文') },
        @{ Name = 'hash-space'; Values = @('-Hash', ' abcdef0', '-Text', '正文') },
        @{ Name = 'hash-empty'; Values = @('-Hash', '', '-Text', '正文') },
        @{ Name = 'hash-missing'; Values = @('-Text', '正文') },
        @{ Name = 'text-empty'; Values = @('-Hash', (Get-TestCommitHash), '-Text', '') },
        @{ Name = 'text-missing'; Values = @('-Hash', (Get-TestCommitHash)) },
        @{ Name = 'text-lf'; Values = @('-Hash', (Get-TestCommitHash), '-Text', "甲`n乙") },
        @{ Name = 'text-cr'; Values = @('-Hash', (Get-TestCommitHash), '-Text', "甲`r乙") },
        @{ Name = 'text-crlf'; Values = @('-Hash', (Get-TestCommitHash), '-Text', "甲`r`n乙") }
    )
    foreach ($invalid in $invalidAdds) {
        Test-Case ('usage-add-' + $invalid.Name + '-before-file-access') {
            $expectedHashLength = if ($invalid.Name.StartsWith('hash-', [StringComparison]::Ordinal)) { 0 } else { 40 }
            $missing = Join-Path $script:CaseDirectory '不存在.md'
            Assert-Message (Invoke-Control (@('-Action', 'add', '-File', $missing) + $invalid.Values) -ExpectedHashLength $expectedHashLength) 'usage' 2
            Assert-NoResidue $missing
            $file = New-StageFile "最近提交`r`n- 原文必须保留`r`n" $true
            $before = [IO.File]::ReadAllBytes($file)
            Assert-Message (Invoke-Control (@('-Action', 'add', '-File', $file) + $invalid.Values) -ExpectedHashLength $expectedHashLength) 'usage' 2
            Assert-Bytes $file $before
            Assert-NoResidue $file
        }
    }

    foreach ($invalid in @(
        @{ Name = 'missing-action'; Values = @() },
        @{ Name = 'empty-action'; Values = @('-Action', '') },
        @{ Name = 'unknown-action'; Values = @('-Action', 'unknown') }
    )) {
        Test-Case ('usage-' + $invalid.Name + '-unchanged') {
            $file = New-StageFile "最近提交`n- 原文`n" $true
            $before = [IO.File]::ReadAllBytes($file)
            Assert-Message (Invoke-Control (@('-File', $file) + $invalid.Values)) 'usage' 2
            Assert-Bytes $file $before
            Assert-NoResidue $file
        }
    }

    foreach ($action in @('add', 'normalize', 'check')) {
        Test-Case ('usage-missing-file-' + $action) {
            $parameters = @('-Action', $action)
            if ($action -eq 'add') { $parameters += @('-Hash', (Get-TestCommitHash), '-Text', '正文') }
            Assert-Message (Invoke-Control $parameters) 'usage' 2
            Assert-NoResidue (Join-Path $script:CaseDirectory 'absent.md')
        }
        Test-Case ('file-missing-' + $action) {
            $file = Join-Path $script:CaseDirectory '不存在 [甲].md'
            $parameters = @('-Action', $action, '-File', $file)
            if ($action -eq 'add') { $parameters += @('-Hash', (Get-TestCommitHash), '-Text', '正文') }
            Assert-Protocol (Invoke-Control $parameters) 1 @('status=file-missing')
            Assert-NoResidue $file
        }
        Test-Case ('no-section-' + $action) {
            $file = New-StageFile "# 阶段表`r`n## 最近提交`r`n- 非匹配标题`r`n 最近提交`r`n- 前面有空格也不是节`r`n" $true
            $before = [IO.File]::ReadAllBytes($file)
            $parameters = @('-Action', $action, '-File', $file)
            if ($action -eq 'add') { $parameters += @('-Hash', (Get-TestCommitHash), '-Text', '正文') }
            Assert-Protocol (Invoke-Control $parameters) 1 @('status=no-commit-section')
            Assert-Bytes $file $before
            Assert-NoResidue $file
        }
        Test-Case ('strict-utf8-invalid-' + $action) {
            $file = New-StageFile "最近提交`n- 原文`n"
            $invalidBytes = [byte[]]($script:Utf8.GetBytes("最近提交`n- ") + @(0xc3, 0x28, 0xff, 0x0a))
            [IO.File]::WriteAllBytes($file, $invalidBytes)
            $parameters = @('-Action', $action, '-File', $file)
            if ($action -eq 'add') { $parameters += @('-Hash', (Get-TestCommitHash), '-Text', '正文') }
            Assert-Message (Invoke-Control $parameters) 'error' 3
            Assert-Bytes $file $invalidBytes
            Assert-NoResidue $file
        }
    }

    foreach ($action in @('add', 'normalize')) {
        Test-Case ('atomic-replace-failure-' + $action) {
            $file = New-StageFile "最近提交`r`n* 必须修改`r`n- 原文`r`n" $true
            $before = [IO.File]::ReadAllBytes($file)
            $handle = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $parameters = @('-Action', $action, '-File', $file)
                if ($action -eq 'add') { $parameters += @('-Hash', (Get-TestCommitHash), '-Text', '正文') }
                Assert-Message (Invoke-Control $parameters) 'error' 3
                Assert-Bytes $file $before
                Assert-NoResidue $file
            } finally { $handle.Dispose() }
            Assert-Bytes $file $before
            Assert-NoResidue $file
        }
    }

    foreach ($pathKind in @('relative', 'dot-relative', 'root-relative', 'slash-root-relative', 'drive-relative', 'extended-device', 'device', 'slash-device', 'ads')) {
        Test-Case ('usage-invalid-path-' + $pathKind) {
            $file = New-StageFile "最近提交`n* 原文`n"
            $before = [IO.File]::ReadAllBytes($file)
            $drive = [IO.Path]::GetPathRoot($file)
            $leaf = [IO.Path]::GetFileName($file)
            $rootRelative = $file.Substring($drive.Length - 1)
            $badPath = switch ($pathKind) {
                'relative' { $leaf }
                'dot-relative' { '.\' + $leaf }
                'root-relative' { $rootRelative }
                'slash-root-relative' { $rootRelative.Replace('\', '/') }
                'drive-relative' { $drive.Substring(0, 2) + $leaf }
                'extended-device' { '\\?\' + $file }
                'device' { '\\.\' + $file }
                'slash-device' { '//?/' + $file.Replace('\', '/') }
                'ads' { $file + ':stream' }
            }
            Assert-Message (Invoke-Control @('-Action', 'normalize', '-File', $badPath)) 'usage' 2
            Assert-Bytes $file $before
            Assert-NoResidue $file
        }
    }

    Test-Case 'usage-existing-directory-not-file' {
        Assert-Message (Invoke-Control @('-Action', 'check', '-File', $script:CaseDirectory)) 'usage' 2
        Assert-NoResidue (Join-Path $script:CaseDirectory 'absent.md')
    }

    Test-Case 'utf16-is-not-autodetected' {
        $file = New-StageFile ''
        $bytes = [byte[]](@(0xff, 0xfe) + [Text.Encoding]::Unicode.GetBytes("最近提交`n- 原文`n"))
        [IO.File]::WriteAllBytes($file, $bytes)
        Assert-Message (Invoke-Control @('-Action', 'normalize', '-File', $file)) 'error' 3
        Assert-Bytes $file $bytes
        Assert-NoResidue $file
    }
} catch {
    $script:FailCount++
    Write-Output ('FAIL startup-or-suite: ' + $_.Exception.Message.Replace("`r", '\r').Replace("`n", '\n'))
} finally {
    try {
        if ($null -ne $script:ActiveProcess) { Stop-OwnedProcess $script:ActiveProcess }
        if ($null -ne $script:OwnDirectory -and [IO.Directory]::Exists($script:OwnDirectory)) {
            [IO.Directory]::Delete($script:OwnDirectory, $true)
            Assert-True (-not [IO.Directory]::Exists($script:OwnDirectory)) 'owned directory survived cleanup'
        }
    } catch {
        $script:FailCount++
        Write-Output ('FAIL cleanup: ' + $_.Exception.Message.Replace("`r", '\r').Replace("`n", '\n'))
    }
}
Write-Output ('summary pass=' + $script:PassCount + ' fail=' + $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
