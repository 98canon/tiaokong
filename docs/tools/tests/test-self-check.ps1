param(
    [string]$TempRoot,
    [string]$ControlRoot,
    [string]$CleanRepoSeed
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:Passed = 0
$script:Failed = 0
$script:Owned = $null
$script:Utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$script:Names = @('dev-marker', 'version', 'git-clean', 'steps', 'control-scripts')
$script:Required = @(
    'steps/new-binding.md', 'steps/lock-conflict.md',
    'steps/full-research.md', 'steps/model-failure.md',
    'scripts/control/bind.ps1', 'scripts/control/lock.ps1',
    'scripts/control/read-section.ps1', 'scripts/control/stage-commit.ps1',
    'scripts/control/self-check.ps1'
)

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-AbsoluteDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))' -or
        $Path -match '^(?:\\\\[?.]|//[?.])' -or
        $Path.Substring(2).Contains(':')) { throw 'absolute filesystem directory required' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full -match '^[A-Za-z]:$') { $full += '\' }
    Assert-That ([IO.Directory]::Exists($full)) 'directory missing'
    return $full
}

function Assert-NoReparse([string]$Path, [bool]$Recursive) {
    $cursor = $Path
    while ($cursor) {
        Assert-That (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse point rejected'
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
    if ($Recursive) {
        foreach ($entry in [IO.Directory]::GetFileSystemEntries($Path)) {
            Assert-That (([IO.File]::GetAttributes($entry) -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse point rejected'
            if ([IO.Directory]::Exists($entry)) { Assert-NoReparse $entry $true }
        }
    }
}

function Get-IsolatedDirectory([string]$Path) {
    $full = Get-AbsoluteDirectory $Path
    Assert-That ($full.StartsWith($script:Temp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) 'directory must be strictly inside TempRoot'
    Assert-NoReparse $full $true
    return $full
}

# Windows CommandLineToArgvW quoting, including empty strings and trailing slashes.
function ConvertTo-WindowsArgument([string]$Value) {
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
        } else {
            [void]$builder.Append(('\' * $slashes))
        }
        [void]$builder.Append($character)
        $slashes = 0
    }
    [void]$builder.Append(('\' * (2 * $slashes)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Stop-OwnedProcessTree([Diagnostics.Process]$Process) {
    if ($Process.HasExited) { return }
    $killer = New-Object Diagnostics.Process
    $killer.StartInfo.FileName = Join-Path $env:SystemRoot 'System32/taskkill.exe'
    $killer.StartInfo.Arguments = '/PID ' + $Process.Id + ' /T /F'
    $killer.StartInfo.UseShellExecute = $false
    $killer.StartInfo.CreateNoWindow = $true
    $killer.StartInfo.RedirectStandardOutput = $true
    $killer.StartInfo.RedirectStandardError = $true
    try {
        Assert-That ($killer.Start()) 'taskkill did not start'
        $killOut = $killer.StandardOutput.ReadToEndAsync()
        $killErr = $killer.StandardError.ReadToEndAsync()
        Assert-That ($killer.WaitForExit(3000)) 'taskkill timed out'
        Assert-That ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($killOut, $killErr), 1000)) 'taskkill streams did not finish'
        Assert-That ($Process.WaitForExit(3000)) 'owned process did not exit'
    } finally { $killer.Dispose() }
}

function Invoke-Child([string]$Executable, [string[]]$Arguments) {
    $remaining = 120000 - [int]$script:Clock.ElapsedMilliseconds
    Assert-That ($remaining -gt 0) '120 second test budget exhausted'
    Assert-That ([IO.File]::Exists($Executable)) ('child startup failed: executable is not a file: ' + $Executable)
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = $script:Utf8
    $process.StartInfo.StandardErrorEncoding = $script:Utf8
    $process.StartInfo.WorkingDirectory = $script:Runtime
    # Do not inherit real user Git configuration or repository overrides.
    foreach ($key in @($process.StartInfo.EnvironmentVariables.Keys)) {
        if ($key -like 'GIT_*') { $process.StartInfo.EnvironmentVariables.Remove($key) }
    }
    $process.StartInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $process.StartInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = Join-Path $script:Runtime 'nonexistent-global-git-config'
    $process.StartInfo.EnvironmentVariables['GIT_CONFIG_SYSTEM'] = Join-Path $script:Runtime 'nonexistent-system-git-config'
    $process.StartInfo.EnvironmentVariables['HOME'] = Join-Path $script:Runtime 'profile'
    $process.StartInfo.EnvironmentVariables['USERPROFILE'] = Join-Path $script:Runtime 'profile'
    $process.StartInfo.EnvironmentVariables['XDG_CONFIG_HOME'] = Join-Path $script:Runtime 'config'
    $process.StartInfo.EnvironmentVariables['APPDATA'] = Join-Path $script:Runtime 'appdata'
    $process.StartInfo.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $script:Runtime 'localappdata'
    $process.StartInfo.EnvironmentVariables['TEMP'] = Join-Path $script:Runtime 'temp'
    $process.StartInfo.EnvironmentVariables['TMP'] = Join-Path $script:Runtime 'temp'
    $process.StartInfo.EnvironmentVariables['PSModuleAnalysisCachePath'] = Join-Path $script:Runtime 'module-analysis.cache'
    if ($script:WithoutGit) { $process.StartInfo.EnvironmentVariables['PATH'] = $script:Owned }
    $started = $false
    try {
        try { $started = $process.Start() }
        catch { throw ('child startup failed: ' + $Executable + ': ' + $_.Exception.Message) }
        Assert-That $started ('child startup failed: ' + $Executable)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit([Math]::Min(30000, $remaining))) {
            Stop-OwnedProcessTree $process
            throw 'child timeout (30 seconds or total budget)'
        }
        Assert-That ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 3000)) 'redirected streams did not finish'
        return [pscustomobject]@{ Code = $process.ExitCode; Out = $stdoutTask.Result; Err = $stderrTask.Result }
    } finally {
        try { if ($started -and -not $process.HasExited) { Stop-OwnedProcessTree $process } }
        finally { $process.Dispose() }
    }
}

function Write-FixtureText([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function New-Skill([string]$Name) {
    $directory = Join-Path $script:Owned ($Name + " 中文 空格' [夹具]")
    [void][IO.Directory]::CreateDirectory($directory)
    Write-FixtureText (Join-Path $directory 'VERSION') "2.4.0`n"
    Write-FixtureText (Join-Path $directory 'CHANGELOG.md') "# Changes`n## 2.4.0`n"
    foreach ($relative in $script:Required) { Write-FixtureText (Join-Path $directory $relative) '' }
    return $directory
}

function Copy-Tree([string]$Source, [string]$Destination) {
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($file in [IO.Directory]::GetFiles($Source)) {
        [IO.File]::Copy($file, (Join-Path $Destination ([IO.Path]::GetFileName($file))), $false)
    }
    foreach ($directory in [IO.Directory]::GetDirectories($Source)) {
        Copy-Tree $directory (Join-Path $Destination ([IO.Path]::GetFileName($directory)))
    }
}

function Get-Snapshot([string]$Root) {
    Assert-NoReparse $Root $true
    $records = @{}
    foreach ($directory in [IO.Directory]::GetDirectories($Root, '*', [IO.SearchOption]::AllDirectories)) {
        $records['D:' + $directory.Substring($Root.Length)] = 'present'
    }
    foreach ($file in [IO.Directory]::GetFiles($Root, '*', [IO.SearchOption]::AllDirectories)) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($file))) }
        finally { $sha.Dispose() }
        $record = 'sha256=' + $hash
        if ([IO.Path]::GetFileName($file) -eq 'index') { $record += ',index_write_ticks=' + [IO.File]::GetLastWriteTimeUtc($file).Ticks }
        $records['F:' + $file.Substring($Root.Length)] = $record
    }
    return $records
}

function Assert-SnapshotUnchanged([hashtable]$Before, [hashtable]$After) {
    $differences = New-Object 'Collections.Generic.List[string]'
    foreach ($key in (@($Before.Keys) + @($After.Keys) | Sort-Object -Unique)) {
        if (-not $Before.ContainsKey($key)) {
            $differences.Add('added ' + $key + ' [' + $After[$key] + ']')
        } elseif (-not $After.ContainsKey($key)) {
            $differences.Add('removed ' + $key + ' [' + $Before[$key] + ']')
        } elseif ($Before[$key] -cne $After[$key]) {
            $differences.Add('changed ' + $key + ' [before ' + $Before[$key] + '; after ' + $After[$key] + ']')
        }
    }
    Assert-That ($differences.Count -eq 0) ('self-check changed files, directories, index bytes/time, or left residue: ' + ($differences -join ' | '))
}

# Prepare engine-owned state before any business fixture or read-only baseline.
# The runtime directory is still included in every subsequent full snapshot.
function Initialize-Runtime {
    $script:Runtime = Join-Path $script:Owned 'runtime'
    foreach ($name in @('', 'profile', 'config', 'appdata', 'localappdata', 'temp')) {
        $path = if ($name) { Join-Path $script:Runtime $name } else { $script:Runtime }
        [void][IO.Directory]::CreateDirectory($path)
    }
    $warmup = Join-Path $script:Runtime 'warmup.ps1'
    $source = @'
param()
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Out-Null
exit 0
'@
    [IO.File]::WriteAllText($warmup, ($source.Replace("`r`n", "`n") + "`n"), (New-Object Text.UTF8Encoding($true)))
    $result = Invoke-Child $script:PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $warmup)
    Assert-That ($result.Code -eq 0 -and $result.Out.Length -eq 0 -and [string]::IsNullOrWhiteSpace($result.Err)) ('runtime warmup failed: code=' + $result.Code + ' stdout=' + $result.Out + ' stderr=' + $result.Err)
    if ($script:GitPath) {
        $result = Invoke-Child $script:GitPath @('--no-optional-locks', '--version')
        Assert-That ($result.Code -eq 0 -and [string]::IsNullOrWhiteSpace($result.Err)) ('Git runtime warmup failed: code=' + $result.Code + ' stderr=' + $result.Err)
    }
}

function Invoke-Check([string]$Skill) {
    $before = Get-Snapshot $script:Owned
    try {
        $result = Invoke-Child $script:PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:Target, '-SkillDir', $Skill)
    } finally {
        $after = Get-Snapshot $script:Owned
        Assert-SnapshotUnchanged $before $after
    }
    Assert-That ([string]::IsNullOrWhiteSpace($result.Err)) ('unexpected stderr: ' + $result.Err)
    return $result
}

function Read-Checks($Result, [string]$Total) {
    Assert-That ($Result.Code -eq $(if ($Total -eq 'pass') { 0 } else { 1 })) ('unexpected exit code ' + $Result.Code)
    $lines = @([regex]::Split($Result.Out, '\r\n|\n|\r'))
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }
    Assert-That ($lines.Count -eq 7) ('expected exactly seven protocol lines, got ' + $lines.Count)
    Assert-That ($lines[0] -ceq ('status=' + $Total)) 'bad first total status'
    Assert-That ($lines[6] -ceq $lines[0]) 'bad last total status'
    $checks = @{}
    for ($index = 0; $index -lt 5; $index++) {
        $match = [regex]::Match($lines[$index + 1], '^check=([a-z-]+);status=(pass|fail|unknown);detail=([^;\r\n]*)$')
        Assert-That ($match.Success) ('bad check format: ' + $lines[$index + 1])
        Assert-That ($match.Groups[1].Value -ceq $script:Names[$index]) 'bad check order'
        $checks[$script:Names[$index]] = [pscustomobject]@{ Status = $match.Groups[2].Value; Detail = $match.Groups[3].Value }
    }
    return $checks
}

function Assert-Statuses($Checks, [string]$FailedItem, [string]$GitStatus = 'unknown') {
    foreach ($name in $script:Names) {
        $expected = if ($name -eq $FailedItem) { 'fail' } elseif ($name -eq 'git-clean') { $GitStatus } else { 'pass' }
        Assert-That ($Checks[$name].Status -ceq $expected) ($name + ' expected ' + $expected + ', got ' + $Checks[$name].Status)
    }
}

function Run-Case([string]$Name, [scriptblock]$Body) {
    try {
        Assert-That ($script:Clock.ElapsedMilliseconds -lt 120000) '120 second test budget exhausted'
        & $Body
        $script:Passed++
        Write-Output ('PASS ' + $Name)
    } catch {
        $script:Failed++
        Write-Output ('FAIL ' + $Name + ': ' + ($_.Exception.Message -replace '[\r\n]+', ' '))
    }
}

try {
    $script:Temp = Get-AbsoluteDirectory $TempRoot
    $systemDrive = [IO.Path]::GetPathRoot($env:SystemRoot)
    Assert-That (-not $script:Temp.StartsWith($systemDrive, [StringComparison]::OrdinalIgnoreCase)) 'TempRoot must not be on the system drive'
    Assert-NoReparse $script:Temp $false
    $formalControl = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../scripts/control')).TrimEnd('\')
    if ($ControlRoot) {
        $control = Get-IsolatedDirectory $ControlRoot
        Assert-That ($control.TrimEnd('\') -ine $formalControl) 'ControlRoot cannot be the formal implementation directory'
    } else { $control = $formalControl }
    if ($CleanRepoSeed) { $script:Seed = Get-IsolatedDirectory $CleanRepoSeed }
} catch {
    Write-Output 'status=usage'
    Write-Output ('message=' + ($_.Exception.Message -replace '[\r\n]+', ' '))
    exit 2
}

try {
    $script:Owned = Join-Path $script:Temp ("self-check 中文 空格' [测试]-" + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:Owned)
    $script:PowerShell = Join-Path $PSHOME 'powershell.exe'
    $script:Target = Join-Path $control 'self-check.ps1'
    Assert-That ([IO.File]::Exists($script:Target)) 'test startup failed: self-check.ps1 missing'
    Assert-That ([IO.File]::Exists($script:PowerShell)) 'test startup failed: Windows PowerShell missing'
    # Get-Command may return more than one application; never stringify .Source arrays.
    $gitCommand = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:GitPath = if ($gitCommand) { [string]$gitCommand.Path } else { $null }
    Initialize-Runtime

    Run-Case 'non-repository unknown still total pass; order, fields, read-only' {
        $skill = New-Skill 'unknown'
        $checks = Read-Checks (Invoke-Check $skill) 'pass'
        Assert-Statuses $checks ''
        Assert-That ($checks.version.Detail -ceq '2.4.0') 'passing version detail must equal version'
    }
    Run-Case 'development marker fails only marker' {
        $skill = New-Skill 'marker'
        Write-FixtureText (Join-Path $skill '.tiaokong-dev') ''
        $checks = Read-Checks (Invoke-Check $skill) 'fail'
        Assert-Statuses $checks 'dev-marker'
        Assert-That ($checks['dev-marker'].Detail -ceq 'development repository') 'marker detail differs'
    }
    Run-Case 'Git unavailable stays unknown without suppressing later checks' {
        $skill = New-Skill 'no-git'
        $script:WithoutGit = $true
        try {
            $checks = Read-Checks (Invoke-Check $skill) 'pass'
            Assert-Statuses $checks ''
        } finally { $script:WithoutGit = $false }
    }
    Run-Case 'version Trim, first line, BOM and CRLF accepted' {
        $skill = New-Skill 'version-trim'
        [IO.File]::WriteAllText((Join-Path $skill 'VERSION'), " 2.4.0 `r`nignored`r`n", (New-Object Text.UTF8Encoding($true)))
        Write-FixtureText (Join-Path $skill 'CHANGELOG.md') "# Log`r`n## release 2.4.0 and 9.9.9`r`n## 8.8.8`r`n"
        $checks = Read-Checks (Invoke-Check $skill) 'pass'
        Assert-Statuses $checks ''
        Assert-That ($checks.version.Detail -ceq '2.4.0') 'wrong extracted version'
    }
    foreach ($bad in @('2.4', '2.4.0.1', 'v2.4.0', '2.4.0-suffix', '2.4.x', '2.4.0 extra', '', 'bad;statement')) {
        Run-Case ('strict version [' + $bad + '] and detail sanitization') {
            $skill = New-Skill ('bad-version-' + [Guid]::NewGuid().ToString('N'))
            Write-FixtureText (Join-Path $skill 'VERSION') ($bad + "`r`n")
            $checks = Read-Checks (Invoke-Check $skill) 'fail'
            Assert-Statuses $checks 'version'
            Assert-That ($checks.version.Detail.Contains('2.4.0')) 'version detail lacks CHANGELOG value'
            if ($bad) { Assert-That ($checks.version.Detail.Contains($bad.Replace(';', ','))) 'detail lacks VERSION value or semicolon was not replaced with comma' }
        }
    }
    foreach ($missing in @('VERSION', 'CHANGELOG.md')) {
        Run-Case ('missing ' + $missing) {
            $skill = New-Skill ('missing-' + $missing)
            [IO.File]::Delete((Join-Path $skill $missing))
            $checks = Read-Checks (Invoke-Check $skill) 'fail'
            Assert-Statuses $checks 'version'
            Assert-That ($checks.version.Detail.Contains('2.4.0')) 'missing-file detail lacks surviving version'
        }
    }
    Run-Case 'empty VERSION file' {
        $skill = New-Skill 'empty-version'
        Write-FixtureText (Join-Path $skill 'VERSION') ''
        $checks = Read-Checks (Invoke-Check $skill) 'fail'
        Assert-Statuses $checks 'version'
        Assert-That ($checks.version.Detail.Contains('2.4.0')) 'empty-file detail lacks CHANGELOG version'
    }
    Run-Case 'first CHANGELOG heading without version cannot use later heading' {
        $skill = New-Skill 'first-heading'
        Write-FixtureText (Join-Path $skill 'CHANGELOG.md') "# Log`n## Unreleased; notes`n## 2.4.0`n"
        $checks = Read-Checks (Invoke-Check $skill) 'fail'
        Assert-Statuses $checks 'version'
        Assert-That ($checks.version.Detail.Contains('2.4.0')) 'detail lacks VERSION value'
    }
    Run-Case 'unequal versions report both values' {
        $skill = New-Skill 'unequal'
        Write-FixtureText (Join-Path $skill 'CHANGELOG.md') "## 3.5.7`n## 2.4.0`n"
        $checks = Read-Checks (Invoke-Check $skill) 'fail'
        Assert-Statuses $checks 'version'
        Assert-That ($checks.version.Detail.Contains('2.4.0') -and $checks.version.Detail.Contains('3.5.7')) 'detail must contain both unequal values'
    }
    foreach ($invalid in @('VERSION', 'CHANGELOG.md')) {
        Run-Case ('strict UTF8 rejection ' + $invalid) {
            $skill = New-Skill ('invalid-' + $invalid)
            [IO.File]::WriteAllBytes((Join-Path $skill $invalid), [byte[]]@(0xC3, 0x28))
            $result = Invoke-Check $skill
            Assert-That ($result.Code -eq 3) 'illegal UTF8 must exit 3'
            Assert-That ($result.Out -match '\Astatus=error\r?\nmessage=[^\r\n]*\r?\n?\z') 'error must not leak partial check protocol'
        }
    }
    foreach ($relative in $script:Required) {
        foreach ($kind in @('missing', 'directory')) {
            Run-Case ($kind + ' required file ' + $relative) {
                $skill = New-Skill ([Guid]::NewGuid().ToString('N'))
                $path = Join-Path $skill $relative
                [IO.File]::Delete($path)
                if ($kind -eq 'directory') { [void][IO.Directory]::CreateDirectory($path) }
                $item = if ($relative.StartsWith('steps/')) { 'steps' } else { 'control-scripts' }
                $checks = Read-Checks (Invoke-Check $skill) 'fail'
                Assert-Statuses $checks $item
                Assert-That ($checks[$item].Detail.Replace('\', '/') -ceq $relative) 'detail must identify exactly the missing relative file'
            }
        }
    }
    Run-Case 'multiple missing files have comma-separated relative detail' {
        $skill = New-Skill 'multiple'
        foreach ($relative in $script:Required) { [IO.File]::Delete((Join-Path $skill $relative)) }
        $checks = Read-Checks (Invoke-Check $skill) 'fail'
        foreach ($item in @('steps', 'control-scripts')) {
            Assert-That ($checks[$item].Status -ceq 'fail') ('missing files not failed: ' + $item)
            $expected = @($script:Required | Where-Object { if ($item -eq 'steps') { $_.StartsWith('steps/') } else { $_.StartsWith('scripts/') } } | Sort-Object)
            $actual = @($checks[$item].Detail.Replace('\', '/').Split(',') | ForEach-Object { $_.Trim() } | Sort-Object)
            Assert-That (($expected -join '|') -ceq ($actual -join '|')) 'missing-file detail set differs'
        }
    }

    foreach ($scenario in @('clean', 'dirty', 'parent')) {
        Run-Case ('Git ' + $scenario + ' fixture and index immutability') {
            Assert-That (-not [string]::IsNullOrWhiteSpace($script:Seed)) 'missing fixture: supply -CleanRepoSeed containing a committed clean fake skill, including .git'
            $copy = Join-Path $script:Owned ("seed $scenario 中文' [仓库]")
            Copy-Tree $script:Seed $copy
            Assert-That ([IO.Directory]::Exists((Join-Path $copy '.git'))) 'seed must contain a local .git directory, not a worktree pointer'
            Assert-That (-not [string]::IsNullOrWhiteSpace($script:GitPath)) 'Git fixture requires an available git.exe'
            $top = Invoke-Child $script:GitPath @('--no-optional-locks', '-C', $copy, 'rev-parse', '--show-toplevel')
            Assert-That ($top.Code -eq 0 -and [IO.Path]::GetFullPath($top.Out.Trim()).TrimEnd('\') -ieq $copy.TrimEnd('\')) 'seed is not its own Git root'
            $initial = Invoke-Child $script:GitPath @('--no-optional-locks', '-C', $copy, 'status', '--porcelain', '--untracked-files=all')
            Assert-That ($initial.Code -eq 0 -and $initial.Out.Length -eq 0) 'seed is not clean'
            $baseline = Read-Checks (Invoke-Check $copy) 'pass'
            Assert-Statuses $baseline '' 'pass'
            if ($scenario -eq 'dirty') {
                Write-FixtureText (Join-Path $copy 'VERSION') "2.4.0`nsecond line is a tracked modification`n"
                Write-FixtureText (Join-Path $copy "dirty 中文' [一];=.txt") 'one'
                Write-FixtureText (Join-Path $copy 'nested dirty/two.txt') 'two'
                $porcelain = Invoke-Child $script:GitPath @('--no-optional-locks', '-C', $copy, 'status', '--porcelain', '--untracked-files=all')
                Assert-That ($porcelain.Code -eq 0) 'fixture Git status failed'
                $count = @([regex]::Split($porcelain.Out.TrimEnd("`r", "`n"), '\r\n|\n|\r')).Count
                Assert-That ($count -eq 3) 'seed must track VERSION and not ignore the two untracked fixture paths'
                $checks = Read-Checks (Invoke-Check $copy) 'fail'
                Assert-Statuses $checks 'git-clean'
                Assert-That ($checks['git-clean'].Detail -ceq '3') 'dirty detail must equal porcelain line count 3'
            } elseif ($scenario -eq 'parent') {
                $child = New-Skill 'nested-source'
                $nested = Join-Path $copy "nested 中文' [非仓库]"
                Copy-Tree $child $nested
                $checks = Read-Checks (Invoke-Check $nested) 'pass'
                Assert-Statuses $checks '' 'unknown'
            }
        }
    }
    foreach ($badSkill in @((Join-Path $script:Owned 'absent'), (Join-Path $script:Owned 'not-directory'))) {
        Run-Case ('SkillDir usage ' + [IO.Path]::GetFileName($badSkill)) {
            if ($badSkill.EndsWith('not-directory')) { Write-FixtureText $badSkill '' }
            $result = Invoke-Check $badSkill
            Assert-That ($result.Code -eq 2 -and $result.Out -match '\Astatus=usage\r?\nmessage=[^\r\n]*\r?\n?\z') 'bad SkillDir must be usage, not a legal self-check state'
        }
    }
} catch {
    $script:Failed++
    Write-Output ('FAIL test-startup-or-harness: ' + ($_.Exception.Message -replace '[\r\n]+', ' '))
} finally {
    if ($script:Owned -and [IO.Directory]::Exists($script:Owned)) {
        try {
            Assert-NoReparse $script:Owned $true
            foreach ($file in [IO.Directory]::GetFiles($script:Owned, '*', [IO.SearchOption]::AllDirectories)) { [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal) }
            [IO.Directory]::Delete($script:Owned, $true)
            Assert-That (-not [IO.Directory]::Exists($script:Owned)) 'owned fixture directory remains'
        } catch {
            $script:Failed++
            Write-Output ('FAIL cleanup: ' + ($_.Exception.Message -replace '[\r\n]+', ' '))
        }
    }
}
Write-Output ('summary pass=' + $script:Passed + ' fail=' + $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
