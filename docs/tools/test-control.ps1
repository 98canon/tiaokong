param(
    [string]$TempRoot = '',
    [string]$CleanRepoSeed = '',
    [string]$TestRoot = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# Local execution tool: only the authorized main session runs this entry point.
# TestRoot is an isolated negative-test override, never an implementation override.
$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:PassCount = 0
$script:FailCount = 0
$script:ExitCode = 1
$script:Fixture = $null
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:ExecutionDeadlineMs = 720000 # 750 seconds including 30 seconds for cleanup.
$script:ValidationMode = 'formal-tests'
# Independently reviewed counts; update only with the formal test contract.
$script:RequiredCaseCounts = @{
    'bind' = 54
    'lock' = 96
    'read-section' = 82
    'stage-commit' = 73
    'self-check' = 43
}

function Write-Case {
    param([string]$Name, [bool]$Passed, [string]$Reason = '')
    if ($Passed) {
        $script:PassCount++
        [Console]::WriteLine('PASS ' + $Name)
    } else {
        $script:FailCount++
        $oneLine = $Reason -replace '[\r\n]+', ' '
        [Console]::WriteLine('FAIL ' + $Name + ': ' + $oneLine)
    }
}

function Get-AbsoluteDirectory {
    param([string]$Value, [string]$Label, [string]$Boundary = '')
    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -match '[\x00-\x1f"<>|*?]' -or
        $Value -match '^[\\/]{2}[?.]' -or
        $Value -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/:]+[\\/][^\\/:]+(?:[\\/]|$))') {
        throw [ArgumentException]::new($Label + ' must be an absolute Windows directory')
    }
    $withoutDrive = $Value -replace '^[A-Za-z]:', ''
    if ($withoutDrive.Contains(':')) {
        throw [ArgumentException]::new($Label + ' cannot contain an alternate data stream')
    }
    $full = [IO.Path]::GetFullPath($Value).Replace('/', '\')
    if (-not [IO.Directory]::Exists($full)) {
        throw [ArgumentException]::new($Label + ' must be an existing directory')
    }
    $systemRoot = [IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows'))
    if ([string]::Equals([IO.Path]::GetPathRoot($full), $systemRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw [ArgumentException]::new($Label + ' must not be on the system drive')
    }
    if ($Boundary) {
        $prefix = $Boundary.TrimEnd([char[]]'\/') + '\'
        if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw [ArgumentException]::new($Label + ' must be strictly inside TempRoot')
        }
    }
    # Inspect every existing ancestor, not just the final directory.
    $directory = New-Object IO.DirectoryInfo($full)
    while ($null -ne $directory) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw [ArgumentException]::new($Label + ' cannot contain a reparse point')
        }
        $directory = $directory.Parent
    }
    return $full
}

function Assert-NoReparseTree {
    param([string]$Directory)
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Directory)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $current -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw [ArgumentException]::new('Isolated override cannot contain reparse points')
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string]$Value)
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $slashes++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, (2 * $slashes + 1))
        } else {
            [void]$builder.Append([char]92, $slashes)
        }
        [void]$builder.Append($character)
        $slashes = 0
    }
    [void]$builder.Append([char]92, (2 * $slashes))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Initialize-JobType {
    # Add-Type's compiler temporary files also belong in our isolated directory.
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    try {
        $env:TEMP = $script:Fixture
        $env:TMP = $script:Fixture
        if ($null -eq ('ControlEntry240.OwnedJob' -as [type])) {
            Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace ControlEntry240 {
    public sealed class OwnedJob : IDisposable {
        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimits {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimits {
            public BasicLimits BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int kind,
            ref ExtendedLimits info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);
        IntPtr handle;
        public OwnedJob() {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero) throw new Win32Exception();
            var limits = new ExtendedLimits();
            limits.BasicLimitInformation.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(handle, 9, ref limits,
                (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) {
                int error = Marshal.GetLastWin32Error();
                Dispose();
                throw new Win32Exception(error);
            }
        }
        public void Attach(IntPtr process) {
            if (!AssignProcessToJobObject(handle, process)) throw new Win32Exception();
        }
        public void Dispose() {
            if (handle != IntPtr.Zero) {
                IntPtr old = handle;
                handle = IntPtr.Zero;
                if (!CloseHandle(old)) throw new Win32Exception();
            }
        }
    }
}
'@
        }
    } finally {
        $env:TEMP = $oldTemp
        $env:TMP = $oldTmp
    }
}

function Invoke-OwnedProcess {
    param([string]$Executable, [string[]]$Values, [int]$TimeoutSeconds,
        [bool]$IsGit = $false)
    $remaining = [int]($script:ExecutionDeadlineMs - $script:Clock.ElapsedMilliseconds - 8000)
    if ($remaining -le 0) { throw 'Entry execution budget exhausted before process launch' }
    $timeoutMs = [Math]::Min(($TimeoutSeconds * 1000), $remaining)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $encoded = @($Values | ForEach-Object { ConvertTo-WindowsArgument -Value $_ })
    $start.Arguments = [string]::Join(' ', [string[]]$encoded)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $script:Utf8
    $start.StandardErrorEncoding = $script:Utf8
    $start.WorkingDirectory = $script:Fixture
    $start.EnvironmentVariables['TEMP'] = $script:Fixture
    $start.EnvironmentVariables['TMP'] = $script:Fixture
    if ($IsGit) {
        # Do not inherit Git redirections, injected config, identities or hooks.
        foreach ($key in @($start.EnvironmentVariables.Keys)) {
            if ($key -like 'GIT_*') { $start.EnvironmentVariables.Remove($key) }
        }
        $start.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
        $start.EnvironmentVariables['GIT_CONFIG_SYSTEM'] = 'NUL'
        $start.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = 'NUL'
        $start.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
        $start.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $job = New-Object ControlEntry240.OwnedJob
    $started = $false
    $stdoutTask = $null
    $stderrTask = $null
    $timedOut = $false
    $failure = ''
    $code = -1
    $stdout = ''
    $stderr = ''
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Process.Start returned false' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $job.Attach($process.Handle)
        if (-not $process.WaitForExit($timeoutMs)) {
            $timedOut = $true
            $failure = 'process timed out'
        } else {
            $code = $process.ExitCode
        }
    } catch {
        $failure = $_.Exception.Message
    } finally {
        # The private job contains only this launch and its descendants; never
        # enumerate/kill unrelated PowerShell, Git or host processes by name.
        try { $job.Dispose() } catch { $failure += '; job cleanup: ' + $_.Exception.Message }
        if ($started) {
            try {
                if (-not $process.HasExited) { $process.Kill() }
                if (-not $process.WaitForExit(3000)) { $failure += '; process did not exit' }
                if ($process.HasExited) { $code = $process.ExitCode }
            } catch { $failure += '; process cleanup: ' + $_.Exception.Message }
        }
        if ($null -ne $stdoutTask -and $null -ne $stderrTask) {
            try {
                $tasks = [Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)
                if (-not [Threading.Tasks.Task]::WaitAll($tasks, 5000)) {
                    $failure += '; redirected stream drain timed out'
                }
                if ($stdoutTask.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) {
                    $stdout = $stdoutTask.Result
                }
                if ($stderrTask.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) {
                    $stderr = $stderrTask.Result
                }
            } catch { $failure += '; redirected stream failure: ' + $_.Exception.Message }
        }
        $process.Dispose()
    }
    return [pscustomobject]@{
        Code = $code; Stdout = $stdout; Stderr = $stderr; TimedOut = $timedOut
        Error = $failure; ElapsedMs = $watch.ElapsedMilliseconds
    }
}

function Write-ProcessResult {
    param([string]$Name, [object]$Result)
    [Console]::WriteLine('child=' + $Name)
    if ($Result.Stdout.Length -gt 0) {
        [Console]::Write($Result.Stdout)
        if (-not $Result.Stdout.EndsWith("`n")) { [Console]::WriteLine() }
    }
    if ($Result.Stderr.Length -gt 0) {
        [Console]::Error.WriteLine('child_stderr=' + $Name)
        [Console]::Error.Write($Result.Stderr)
        if (-not $Result.Stderr.EndsWith("`n")) { [Console]::Error.WriteLine() }
    }
    [Console]::WriteLine('child_code=' + $Result.Code)
    [Console]::WriteLine('child_timeout=' + $Result.TimedOut.ToString().ToLowerInvariant())
    [Console]::WriteLine('child_elapsed_ms=' + $Result.ElapsedMs)
    if ($Result.Error) {
        [Console]::WriteLine('child_error=' + ($Result.Error -replace '[\r\n]+', ' '))
    }
}

function Invoke-TestFile {
    param([string]$File, [string[]]$Parameters, [int]$TimeoutSeconds = 135)
    $values = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $File)
    return Invoke-OwnedProcess -Executable $script:PowerShellExe -Values ($values + $Parameters) `
        -TimeoutSeconds $TimeoutSeconds
}

function Test-ArgumentRoundTrip {
    $echoFile = Join-Path $script:Fixture 'argv-echo.ps1'
    $echoSource = @'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$encoding = New-Object System.Text.UTF8Encoding($false)
[Console]::WriteLine('count=' + $args.Count)
for ($index = 0; $index -lt $args.Count; $index++) {
    [Console]::WriteLine($index.ToString() + '=' + [Convert]::ToBase64String($encoding.GetBytes([string]$args[$index])))
}
'@
    [IO.File]::WriteAllText($echoFile, ($echoSource -replace "`r`n", "`n"),
        (New-Object Text.UTF8Encoding($true)))
    $values = @('space value', '中文', "single'quote", 'double"quote', '[brackets]',
        'a=b', '', 'trailing\', 'two trailing\\', 'slash\"quote')
    $result = Invoke-TestFile -File $echoFile -Parameters $values -TimeoutSeconds 30
    Write-ProcessResult -Name 'argv-roundtrip' -Result $result
    if ($result.Code -ne 0 -or $result.TimedOut -or $result.Error -or $result.Stderr) {
        throw 'Argument echo process failed'
    }
    $expected = @('count=' + $values.Count)
    for ($index = 0; $index -lt $values.Count; $index++) {
        $expected += $index.ToString() + '=' +
            [Convert]::ToBase64String($script:Utf8.GetBytes($values[$index]))
    }
    $actual = $result.Stdout.TrimEnd([char[]]"`r`n") -split '\r?\n'
    if ($actual.Count -ne $expected.Count) { throw 'Argument round-trip line count mismatch' }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if (-not [string]::Equals($actual[$index], $expected[$index], [StringComparison]::Ordinal)) {
            throw ('Argument round-trip mismatch at output line ' + $index)
        }
    }
}

function New-CleanSeed {
    $seed = Join-Path $script:Fixture 'clean-skill-seed'
    $steps = Join-Path $seed 'steps'
    $controls = Join-Path $seed 'scripts\control'
    $hooks = Join-Path $script:Fixture 'empty-hooks'
    $template = Join-Path $script:Fixture 'empty-git-template'
    foreach ($directory in @($seed, $steps, $controls, $hooks, $template)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    [IO.File]::WriteAllText((Join-Path $seed 'VERSION'), "2.4.0`n", $script:Utf8)
    [IO.File]::WriteAllText((Join-Path $seed 'CHANGELOG.md'), "# Changelog`n`n## 2.4.0`n", $script:Utf8)
    foreach ($name in @('new-binding', 'lock-conflict', 'full-research', 'model-failure')) {
        [IO.File]::WriteAllText((Join-Path $steps ($name + '.md')), "# Fixture`n", $script:Utf8)
    }
    foreach ($name in @('bind', 'lock', 'read-section', 'stage-commit', 'self-check')) {
        [IO.File]::WriteAllText((Join-Path $controls ($name + '.ps1')), '', $script:Utf8)
    }
    $git = Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $prefix = @('--no-optional-locks', '-c', 'user.name=Control Fixture',
        '-c', 'user.email=fixture@example.invalid', '-c', ('core.hooksPath=' + $hooks),
        '-c', 'core.fsmonitor=false', '-c', 'commit.gpgSign=false',
        '-c', 'core.autocrlf=false', '-c', 'core.attributesFile=NUL',
        '-c', 'core.excludesFile=NUL', '-C', $seed)
    # These writes happen only when the authorized main session runs this tool.
    $commands = @(
        @{ Name = 'seed-init'; Values = @('init', ('--template=' + $template)) },
        @{ Name = 'seed-add'; Values = @('add', '--', '.') },
        @{ Name = 'seed-commit'; Values = @('commit', '--no-gpg-sign', '-m', 'Isolated clean fixture') },
        @{ Name = 'seed-status'; Values = @('status', '--porcelain', '--untracked-files=all') }
    )
    foreach ($command in $commands) {
        $result = Invoke-OwnedProcess -Executable $git.Source -Values ($prefix + $command.Values) `
            -TimeoutSeconds 30 -IsGit $true
        Write-ProcessResult -Name $command.Name -Result $result
        if ($result.Code -ne 0 -or $result.TimedOut -or $result.Error) {
            throw ('Clean seed preparation failed: ' + $command.Name)
        }
        if ($command.Name -eq 'seed-status' -and $result.Stdout.Length -ne 0) {
            throw 'Prepared seed is not Git clean'
        }
    }
    return $seed
}

function Get-TestFailure {
    param([object]$Result, [int]$RequiredCaseCount = 0)
    $problems = New-Object 'Collections.Generic.List[string]'
    if ($Result.TimedOut) { $problems.Add('child timeout') }
    if ($Result.Error) { $problems.Add($Result.Error) }
    if ($Result.Code -ne 0) { $problems.Add('exit code ' + $Result.Code) }
    if (($Result.Stdout + "`n" + $Result.Stderr) -match '(?m)^FAIL(?:\s|$)') {
        $problems.Add('child emitted FAIL')
    }
    $lines = @($Result.Stdout.TrimEnd([char[]]"`r`n") -split '\r?\n')
    $actualPass = @($lines | Where-Object { $_ -match '^PASS\s+\S' }).Count
    $actualFail = @($lines | Where-Object { $_ -match '^FAIL(?:\s|$)' }).Count
    $last = $lines[$lines.Count - 1]
    if ($last -notmatch '^summary pass=([0-9]+) fail=([0-9]+)$') {
        $problems.Add('missing or malformed final summary')
    } else {
        $summaryPass = [long]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
        $summaryFail = [long]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture)
        if ($summaryFail -ne 0) { $problems.Add('summary reports failures') }
        if ($summaryPass -lt 1) { $problems.Add('no passing cases executed') }
        if ($summaryPass -ne $actualPass -or $summaryFail -ne $actualFail) {
            $problems.Add('summary does not match case output')
        }
    }
    $actualTotal = $actualPass + $actualFail
    if ($RequiredCaseCount -gt 0 -and $actualTotal -ne $RequiredCaseCount) {
        $problems.Add('required case count mismatch: expected=' + $RequiredCaseCount + '; actual=' + $actualTotal)
    }
    return [string]::Join('; ', $problems.ToArray())
}

function Remove-OwnedFixture {
    param([string]$Directory)
    # Never recurse into links left by a child test; delete only the link itself.
    if (([IO.File]::GetAttributes($Directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        [IO.Directory]::Delete($Directory, $false)
        return
    }
    foreach ($item in (Get-ChildItem -LiteralPath $Directory -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) }
            else { [IO.File]::Delete($item.FullName) }
        } elseif ($item.PSIsContainer) {
            Remove-OwnedFixture -Directory $item.FullName
        } else {
            if (($item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
                $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
            }
            [IO.File]::Delete($item.FullName)
        }
        if ($script:Clock.ElapsedMilliseconds -ge 748000) {
            throw 'Entry cleanup budget exhausted; owned fixture remains'
        }
    }
    [IO.Directory]::Delete($Directory, $false)
}

try {
    # Manual validation is deliberately inside try, without Mandatory/ValidateSet.
    try {
        $TempRoot = Get-AbsoluteDirectory -Value $TempRoot -Label 'TempRoot'
        if ($CleanRepoSeed) {
            $CleanRepoSeed = Get-AbsoluteDirectory -Value $CleanRepoSeed -Label 'CleanRepoSeed' -Boundary $TempRoot
            Assert-NoReparseTree -Directory $CleanRepoSeed
        }
        if ($PSBoundParameters.ContainsKey('TestRoot')) {
            $TestRoot = Get-AbsoluteDirectory -Value $TestRoot -Label 'TestRoot' -Boundary $TempRoot
            Assert-NoReparseTree -Directory $TestRoot
            $script:ValidationMode = 'isolated-stubs'
        } else {
            $TestRoot = Join-Path $PSScriptRoot 'tests'
        }
    } catch [ArgumentException] {
        [Console]::WriteLine('status=usage')
        [Console]::WriteLine('message=' + ($_.Exception.Message -replace '[\r\n]+', ' '))
        $script:ExitCode = 2
        throw
    }
    [Console]::WriteLine('validation_mode=' + $script:ValidationMode)
    $candidate = Join-Path $TempRoot ('test-control-' + [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $candidate) { throw 'Random fixture already exists' }
    [void][IO.Directory]::CreateDirectory($candidate)
    $script:Fixture = $candidate
    $script:PowerShellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not [IO.File]::Exists($script:PowerShellExe)) { throw 'Windows PowerShell executable missing' }
    Initialize-JobType
    try {
        Test-ArgumentRoundTrip
        Write-Case -Name 'argv-roundtrip' -Passed $true
    } catch {
        Write-Case -Name 'argv-roundtrip' -Passed $false -Reason $_.Exception.Message
        throw 'Cannot trust child arguments; no tests launched'
    }
    $seedReady = $false
    try {
        if (-not $CleanRepoSeed) { $CleanRepoSeed = New-CleanSeed }
        $seedReady = $true
        Write-Case -Name 'clean-seed-ready' -Passed $true
    } catch {
        Write-Case -Name 'clean-seed-ready' -Passed $false -Reason $_.Exception.Message
    }
    foreach ($name in @('bind', 'lock', 'read-section', 'stage-commit', 'self-check')) {
        try {
            $testFile = Join-Path $TestRoot ('test-' + $name + '.ps1')
            if (-not [IO.File]::Exists($testFile)) { throw ('Missing test file: ' + $testFile) }
            if (([IO.File]::GetAttributes($testFile) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Test file cannot be a reparse point: ' + $testFile)
            }
            $parameters = @('-TempRoot', $TempRoot)
            if ($name -eq 'self-check') {
                if (-not $seedReady) {
                    throw 'Clean seed unavailable; mandatory Git clean/dirty tests cannot be executed'
                }
                $parameters += @('-CleanRepoSeed', $CleanRepoSeed)
            }
            $result = Invoke-TestFile -File $testFile -Parameters $parameters -TimeoutSeconds 135
            Write-ProcessResult -Name $name -Result $result
            $requiredCaseCount = 0
            if ($script:ValidationMode -eq 'formal-tests') {
                $requiredCaseCount = $script:RequiredCaseCounts[$name]
            }
            $reason = Get-TestFailure -Result $result -RequiredCaseCount $requiredCaseCount
            Write-Case -Name $name -Passed ([string]::IsNullOrEmpty($reason)) -Reason $reason
        } catch {
            Write-Case -Name $name -Passed $false -Reason $_.Exception.Message
        }
    }
} catch {
    Write-Case -Name 'entry' -Passed $false -Reason $_.Exception.Message
} finally {
    if ($script:Fixture -and [IO.Directory]::Exists($script:Fixture)) {
        try {
            Remove-OwnedFixture -Directory $script:Fixture
            Write-Case -Name 'fixture-cleanup' -Passed $true
        } catch {
            Write-Case -Name 'fixture-cleanup' -Passed $false -Reason $_.Exception.Message
            [Console]::WriteLine('fixture_remaining=' + $script:Fixture)
        }
    }
    if ($script:Clock.ElapsedMilliseconds -ge 750000) {
        Write-Case -Name 'entry-budget' -Passed $false -Reason '750 second entry budget exceeded'
    }
    if ($script:FailCount -eq 0) {
        $script:ExitCode = 0
        [Console]::WriteLine('result=pass')
    } else {
        if ($script:ExitCode -ne 2) { $script:ExitCode = 1 }
        [Console]::WriteLine('result=fail')
    }
    [Console]::WriteLine('summary pass=' + $script:PassCount + ' fail=' + $script:FailCount)
}
exit $script:ExitCode
