param(
    [string]$TempRoot,
    [string]$ControlRoot
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

# Independent contract tests. Never dot-source or read the implementation.
$script:pass = 0
$script:fail = 0
$script:ownedRoot = $null
$script:clock = [Diagnostics.Stopwatch]::StartNew()
$script:utf8 = New-Object System.Text.UTF8Encoding($false, $true)

function Test-AbsolutePath([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    if ($Value -match '^[\\/]{2}[?.][\\/]') { return $false }
    if ($Value -match '^[A-Za-z]:[\\/]') { return ($Value.Substring(2) -notmatch ':') }
    return ($Value -match '^[\\/]{2}[^\\/:]+[\\/][^\\/:]+(?:[\\/][^:]*)?$')
}

function Assert-NoReparse([string]$Directory) {
    $item = New-Object IO.DirectoryInfo($Directory)
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'ControlRoot must not contain reparse points'
        }
        $item = $item.Parent
    }
}

# CommandLineToArgvW/CRT quoting, including empty values and trailing slashes.
function ConvertTo-WindowsArgument([string]$Value) {
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
        } else {
            [void]$builder.Append(('\' * $slashes))
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    [void]$builder.Append(('\' * (2 * $slashes)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Stop-OwnedProcessTree([Diagnostics.Process]$Process) {
    if ($Process.HasExited) { return }
    $killer = New-Object Diagnostics.Process
    try {
        $killer.StartInfo = New-Object Diagnostics.ProcessStartInfo
        $killer.StartInfo.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        $killer.StartInfo.Arguments = '/PID ' + $Process.Id + ' /T /F'
        $killer.StartInfo.UseShellExecute = $false
        $killer.StartInfo.CreateNoWindow = $true
        $killer.StartInfo.RedirectStandardOutput = $true
        $killer.StartInfo.RedirectStandardError = $true
        if (-not $killer.Start()) { throw 'Cannot start process-tree cleanup' }
        $outTask = $killer.StandardOutput.ReadToEndAsync()
        $errTask = $killer.StandardError.ReadToEndAsync()
        if (-not $killer.WaitForExit(3000)) {
            $killer.Kill()
            throw 'Process-tree cleanup timed out'
        }
        if (-not $Process.WaitForExit(2000)) { throw 'Owned process did not exit' }
        if (-not $outTask.Wait(1000) -or -not $errTask.Wait(1000)) {
            throw 'Process-tree cleanup streams timed out'
        }
    } finally { $killer.Dispose() }
}

function Invoke-Control([string[]]$Parameters) {
    if (-not [IO.File]::Exists($script:target)) { throw 'TEST START FAILURE: read-section.ps1 missing' }
    $remaining = 120000 - [int]$script:clock.ElapsedMilliseconds
    if ($remaining -le 0) { throw 'Test total budget of 120 seconds exceeded' }
    $process = New-Object Diagnostics.Process
    $started = $false
    try {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $PSHOME 'powershell.exe'
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:target) + $Parameters
        $start.Arguments = (($arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = $script:utf8
        $start.StandardErrorEncoding = $script:utf8
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'TEST START FAILURE: PowerShell did not start' }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit([Math]::Min(30000, $remaining))) {
            Stop-OwnedProcessTree $process
            [void]$stdoutTask.Wait(1000)
            [void]$stderrTask.Wait(1000)
            throw 'Child process timeout (30 seconds or remaining total budget)'
        }
        if (-not $stdoutTask.Wait(2000) -or -not $stderrTask.Wait(2000)) {
            throw 'Child output stream timeout'
        }
        return [pscustomobject]@{ Code = $process.ExitCode; Out = $stdoutTask.Result; Err = $stderrTask.Result }
    } finally {
        try { if ($started -and -not $process.HasExited) { Stop-OwnedProcessTree $process } }
        finally { $process.Dispose() }
    }
}

function Get-OutputLines([string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n")
    if ($normalized.Contains("`r")) { throw 'Unexpected bare CR in protocol' }
    if ($normalized.EndsWith("`n")) { $normalized = $normalized.Substring(0, $normalized.Length - 1) }
    return $normalized.Split([char]10)
}

function Assert-Result([string[]]$Parameters, [int]$Code, [string[]]$Expected) {
    $result = Invoke-Control $Parameters
    if ($result.Code -ne $Code) { throw "Exit expected $Code, actual $($result.Code); stdout=$($result.Out); stderr=$($result.Err)" }
    if ($result.Err.Length -ne 0) { throw "Unexpected stderr: $($result.Err)" }
    $actual = @(Get-OutputLines $result.Out)
    if ($actual.Count -ne $Expected.Count -or (($actual -join "`n") -cne ($Expected -join "`n"))) {
        throw "Full output mismatch; expected=[$($Expected -join ' / ')]; actual=[$($actual -join ' / ')]"
    }
}

function Assert-Message([string[]]$Parameters, [string]$Status, [int]$Code) {
    $result = Invoke-Control $Parameters
    $actual = @(Get-OutputLines $result.Out)
    if ($result.Code -ne $Code -or $result.Err.Length -ne 0 -or $actual.Count -ne 2 -or
        $actual[0] -cne ('status=' + $Status) -or $actual[1] -cnotmatch '^message=.+$') {
        throw "Expected exact $Status/message protocol and exit $Code; actual code=$($result.Code), out=$($result.Out), err=$($result.Err)"
    }
    if ($Status -eq 'usage' -and $actual[1] -notmatch '^message=[\x20-\x7e]+$') {
        throw 'Usage message must be one English line'
    }
}

function New-Fixture([string]$Text, [switch]$Bom, [byte[]]$Bytes) {
    $path = Join-Path $script:caseRoot "中文 空格'方[括]号.md"
    if ($null -eq $Bytes) {
        $Bytes = $script:utf8.GetBytes($Text)
        if ($Bom) { $Bytes = [byte[]](@(239, 187, 191) + $Bytes) }
    }
    [IO.File]::WriteAllBytes($path, $Bytes)
    $script:originals.Add([pscustomobject]@{ Path = $path; Bytes = [Convert]::ToBase64String($Bytes) })
    return $path
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    $script:caseRoot = Join-Path $script:ownedRoot ([Guid]::NewGuid().ToString('N'))
    $script:originals = New-Object 'Collections.Generic.List[object]'
    $failure = $null
    try {
        [void][IO.Directory]::CreateDirectory($script:caseRoot)
        & $Body
    } catch { $failure = $_.Exception.Message }
    finally {
        foreach ($original in $script:originals) {
            try {
                if (-not [IO.File]::Exists($original.Path) -or
                    [Convert]::ToBase64String([IO.File]::ReadAllBytes($original.Path)) -cne $original.Bytes) {
                    throw 'Input file bytes changed'
                }
            } catch { $failure = "$failure; byte invariant: $($_.Exception.Message)" }
        }
        try { if ([IO.Directory]::Exists($script:caseRoot)) { [IO.Directory]::Delete($script:caseRoot, $true) } }
        catch { $failure = "$failure; cleanup: $($_.Exception.Message)" }
    }
    if ($null -eq $failure) { $script:pass++; Write-Output "PASS $Name" }
    else { $script:fail++; Write-Output "FAIL ${Name}: $($failure.Replace("`r", ' ').Replace("`n", ' '))" }
}

try {
    if (-not (Test-AbsolutePath $TempRoot) -or -not [IO.Directory]::Exists($TempRoot)) { throw 'TempRoot must be an existing absolute directory' }
    $TempRoot = [IO.Path]::GetFullPath($TempRoot)
    $systemRoot = [IO.Path]::GetPathRoot($env:SystemRoot)
    if ([IO.Path]::GetPathRoot($TempRoot).Equals($systemRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'TempRoot must not be on the system drive' }
    if ($PSBoundParameters.ContainsKey('ControlRoot')) {
        if (-not (Test-AbsolutePath $ControlRoot) -or -not [IO.Directory]::Exists($ControlRoot)) { throw 'ControlRoot must be an existing absolute directory' }
        $ControlRoot = [IO.Path]::GetFullPath($ControlRoot)
        $boundary = $TempRoot.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
        if (-not $ControlRoot.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'ControlRoot must be inside TempRoot' }
        Assert-NoReparse $ControlRoot
    } else {
        $ControlRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\scripts\control'))
    }
} catch {
    Write-Output 'status=usage'
    Write-Output ('message=' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' '))
    exit 2
}

$script:target = Join-Path $ControlRoot 'read-section.ps1'
try {
    $script:ownedRoot = Join-Path $TempRoot ('read-section-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:ownedRoot)
    $actions = @('headings', 'section', 'lines', 'stage')
    foreach ($action in $actions) {
        Test-Case "missing-file-parameter-$action" {
            $parameters = @('-Action', $action)
            if ($action -eq 'section') { $parameters += @('-Headings', 'A') }
            if ($action -eq 'lines') { $parameters += @('-Match', 'A') }
            Assert-Message $parameters 'usage' 2
        }
        Test-Case "empty-file-parameter-$action" {
            $parameters = @('-Action', $action, '-File', '')
            if ($action -eq 'section') { $parameters += @('-Headings', 'A') }
            if ($action -eq 'lines') { $parameters += @('-Match', 'A') }
            Assert-Message $parameters 'usage' 2
        }
        Test-Case "file-missing-$action" {
            $parameters = @('-Action', $action, '-File', (Join-Path $script:caseRoot 'absent.md'))
            if ($action -eq 'section') { $parameters += @('-Headings', 'A') }
            if ($action -eq 'lines') { $parameters += @('-Match', 'A') }
            Assert-Result $parameters 1 @('status=file-missing')
        }
        Test-Case "directory-not-file-$action" {
            $parameters = @('-Action', $action, '-File', $script:caseRoot)
            if ($action -eq 'section') { $parameters += @('-Headings', 'A') }
            if ($action -eq 'lines') { $parameters += @('-Match', 'A') }
            Assert-Message $parameters 'usage' 2
        }
        Test-Case "invalid-utf8-$action" {
            $file = New-Fixture -Bytes ([byte[]]@(35, 35, 32, 65, 10, 195, 40))
            $parameters = @('-Action', $action, '-File', $file)
            if ($action -eq 'section') { $parameters += @('-Headings', 'A') }
            if ($action -eq 'lines') { $parameters += @('-Match', 'A') }
            Assert-Message $parameters 'error' 3
        }
        Test-Case "utf16-not-utf8-$action" {
            $file = New-Fixture -Bytes ([byte[]]@(255, 254, 65, 0))
            $parameters = @('-Action', $action, '-File', $file)
            if ($action -eq 'section') { $parameters += @('-Headings', 'A') }
            if ($action -eq 'lines') { $parameters += @('-Match', 'A') }
            Assert-Message $parameters 'error' 3
        }
    }
    Test-Case 'missing-action' {
        $file = New-Fixture 'x'
        Assert-Message @('-File', $file) 'usage' 2
    }
    Test-Case 'missing-all-parameters' { Assert-Message @() 'usage' 2 }
    Test-Case 'unknown-action-before-file-access' {
        Assert-Message @('-Action', 'not-an-action', '-File', (Join-Path $script:caseRoot 'absent.md')) 'usage' 2
    }
    $invalidPaths = @('relative.md', 'X:relative.md', '\root-relative.md', '\\?\X:\device.md', '\\.\X:\device.md', '\\server', '\\server\', (Join-Path $TempRoot 'file.md:stream'))
    foreach ($invalidPath in $invalidPaths) {
        foreach ($action in $actions) {
            Test-Case "illegal-path-$action-$invalidPath" {
                $parameters = @('-Action', $action, '-File', $invalidPath)
                if ($action -eq 'section') { $parameters += @('-Headings', 'A') }
                if ($action -eq 'lines') { $parameters += @('-Match', 'A') }
                Assert-Message $parameters 'usage' 2
            }
        }
    }
    foreach ($action in @('section', 'lines')) {
        $parameterName = if ($action -eq 'section') { '-Headings' } else { '-Match' }
        Test-Case "missing-request-$action-before-file-access" {
            Assert-Message @('-Action', $action, '-File', (Join-Path $script:caseRoot 'absent.md')) 'usage' 2
        }
        foreach ($request in @('', '|A', 'A|', 'A||B')) {
            Test-Case "empty-request-$action-[$request]" {
                $file = New-Fixture "## A`nx"
                Assert-Message @('-Action', $action, '-File', $file, $parameterName, $request) 'usage' 2
            }
        }
    }
    Test-Case 'duplicate-section-request' {
        $file = New-Fixture "## A`nx"
        Assert-Message @('-Action', 'section', '-File', $file, '-Headings', 'A|A') 'usage' 2
    }
    foreach ($lineEnding in @("`n", "`r`n")) {
        foreach ($trailing in @($false, $true)) {
            $formatName = if ($lineEnding -eq "`n") { 'LF' } else { 'CRLF' }
            Test-Case "all-actions-$formatName-trailing-$trailing" {
                $source = @('preamble', '## Alpha', '中文 text', '### nested', '', 'status=fake', '## Secret', 'DO NOT LEAK', '## Beta', '* hidden', '*ordinary', ' * indented', '*', ('*'+"`t"+'tab'), 'last')
                $text = $source -join $lineEnding
                if ($trailing) { $text += $lineEnding }
                $file = New-Fixture $text
                Assert-Result @('-Action', 'headings', '-File', $file) 0 @('status=ok', 'heading=2:Alpha', 'heading=7:Secret', 'heading=9:Beta')
                Assert-Result @('-Action', 'section', '-File', $file, '-Headings', 'Beta|Alpha') 0 @('status=ok', 'begin=Beta', '## Beta', '* hidden', '*ordinary', ' * indented', '*', ('*'+"`t"+'tab'), 'last', 'end=Beta', 'begin=Alpha', '## Alpha', '中文 text', '### nested', '', 'status=fake', 'end=Alpha')
                Assert-Result @('-Action', 'lines', '-File', $file, '-Match', 'nested|text') 0 @('status=ok', 'count=2', 'line=3:中文 text', 'line=4:### nested')
                Assert-Result @('-Action', 'stage', '-File', $file) 0 @('status=ok', 'preamble', '## Alpha', '中文 text', '### nested', '', 'status=fake', '## Secret', 'DO NOT LEAK', '## Beta', '*ordinary', ' * indented', '*', ('*'+"`t"+'tab'), 'last')
            }
        }
    }
    Test-Case 'empty-file-all-actions' {
        $file = New-Fixture ''
        Assert-Result @('-Action', 'headings', '-File', $file) 0 @('status=ok')
        Assert-Result @('-Action', 'section', '-File', $file, '-Headings', 'A') 1 @('status=partial', 'missing=A')
        Assert-Result @('-Action', 'lines', '-File', $file, '-Match', 'A') 0 @('status=ok', 'count=0')
        Assert-Result @('-Action', 'stage', '-File', $file) 0 @('status=ok')
    }
    Test-Case 'bom-and-real-empty-lines' {
        $file = New-Fixture "`n## A`n`n`n" -Bom
        Assert-Result @('-Action', 'headings', '-File', $file) 0 @('status=ok', 'heading=2:A')
        Assert-Result @('-Action', 'section', '-File', $file, '-Headings', 'A') 0 @('status=ok', 'begin=A', '## A', '', '', 'end=A')
        Assert-Result @('-Action', 'stage', '-File', $file) 0 @('status=ok', '', '## A', '', '')
    }
    Test-Case 'exact-case-title-spacing-and-first-duplicate' {
        $file = New-Fixture "## A`nfirst`n## a`nlower`n## A `nspace`n## A`nsecond`n## Tail`nend"
        Assert-Result @('-Action', 'section', '-File', $file, '-Headings', 'a|A |A|Tail') 0 @('status=ok', 'begin=a', '## a', 'lower', 'end=a', 'begin=A ', '## A ', 'space', 'end=A ', 'begin=A', '## A', 'first', 'end=A', 'begin=Tail', '## Tail', 'end', 'end=Tail')
    }
    Test-Case 'partial-missing-order-no-unrequested-output' {
        $file = New-Fixture "## A`nselected`n## Secret`nPRIVATE`n## a`nlower"
        Assert-Result @('-Action', 'section', '-File', $file, '-Headings', 'MissingZ|A|MissingA') 1 @('status=partial', 'begin=A', '## A', 'selected', 'end=A', 'missing=MissingZ|MissingA')
        Assert-Result @('-Action', 'section', '-File', $file, '-Headings', 'MissingZ|MissingA') 1 @('status=partial', 'missing=MissingZ|MissingA')
        Assert-Result @('-Action', 'section', '-File', $file, '-Headings', 'AA') 1 @('status=partial', 'missing=AA')
    }
    Test-Case 'headings-exact-prefix-and-title-not-trimmed' {
        $file = New-Fixture "# one`n### three`n ## indented`n##`n##NoSpace`n## A `n##  B`n## "
        Assert-Result @('-Action', 'headings', '-File', $file) 0 @('status=ok', 'heading=6:A ', 'heading=7: B', 'heading=8:')
    }
    Test-Case 'literal-regex-case-multiple-hits-one-line' {
        $file = New-Fixture "a.b [x] a+b ^ $ (q) \\`naxb x aaab`nCase case`ncase`nCASE`nnone"
        Assert-Result @('-Action', 'lines', '-File', $file, '-Match', 'a.b|[x]|a+b|^|$|(q)|\\') 0 @('status=ok', 'count=1', 'line=1:a.b [x] a+b ^ $ (q) \\')
        Assert-Result @('-Action', 'lines', '-File', $file, '-Match', 'Case') 0 @('status=ok', 'count=1', 'line=3:Case case')
        Assert-Result @('-Action', 'lines', '-File', $file, '-Match', 'not-present') 0 @('status=ok', 'count=0')
        Assert-Result @('-Action', 'lines', '-File', $file, '-Match', 'case|case') 0 @('status=ok', 'count=2', 'line=3:Case case', 'line=4:case')
    }
    Test-Case 'literal-double-quote-equals-and-trailing-backslash-argument' {
        $file = New-Fixture 'literal "quoted"=value\'
        Assert-Result @('-Action', 'lines', '-File', $file, '-Match', '"quoted"=value\') 0 @('status=ok', 'count=1', 'line=1:literal "quoted"=value\')
    }
    Test-Case 'stage-only-star-space-not-star-tab-or-indented' {
        $file = New-Fixture "* hidden`n* `n** bold`n*plain`n*`n * keep`n*`tkeep`n- keep`n`nlast"
        Assert-Result @('-Action', 'stage', '-File', $file) 0 @('status=ok', '** bold', '*plain', '*', ' * keep', "*`tkeep", '- keep', '', 'last')
    }
} catch {
    $script:fail++
    Write-Output ('FAIL suite: ' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' '))
} finally {
    if ($null -ne $script:ownedRoot -and [IO.Directory]::Exists($script:ownedRoot)) {
        try { [IO.Directory]::Delete($script:ownedRoot, $true) }
        catch { $script:fail++; Write-Output ('FAIL suite-cleanup: ' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' ')) }
    }
}
Write-Output "summary pass=$script:pass fail=$script:fail"
if ($script:fail -gt 0) { exit 1 }
exit 0
