param($SkillDir)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Stop-Usage {
    param([string]$Message)
    $exception = New-Object System.ArgumentException($Message)
    $exception.Data['self-check-usage'] = $true
    throw $exception
}

function Get-PathKind {
    param([string]$Path)
    try {
        $attributes = [System.IO.File]::GetAttributes($Path)
    }
    catch [System.IO.FileNotFoundException] { return 'missing' }
    catch [System.IO.DirectoryNotFoundException] { return 'missing' }
    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
        return 'directory'
    }
    return 'file'
}

function Get-AbsolutePath {
    param([string]$Path)
    $windowsPath = $Path.Replace('/', '\')
    if ($windowsPath -notmatch '\A(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|\z))' -or
        $windowsPath -match '\A\\\\[?.]\\' -or
        $windowsPath -match '[\x00-\x1f<>"|?*]' -or
        $windowsPath.Substring(2).Contains(':')) {
        Stop-Usage 'SkillDir must be an absolute Windows filesystem path'
    }
    try { return [System.IO.Path]::GetFullPath($windowsPath) }
    catch [System.ArgumentException] { Stop-Usage 'SkillDir is not a valid path' }
    catch [System.NotSupportedException] { Stop-Usage 'SkillDir is not a valid path' }
    catch [System.IO.PathTooLongException] { Stop-Usage 'SkillDir is not a valid path' }
}

function Read-StrictUtf8 {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and
        $bytes[1] -eq 187 -and $bytes[2] -eq 191) { $offset = 3 }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    return $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
}

function New-Check {
    param([string]$Name, [string]$Status, [string]$Detail)
    [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }
}

function Invoke-ReadOnlyGit {
    param([string]$GitPath, [string[]]$GitArguments)
    $savedPreference = $ErrorActionPreference
    try {
        # PS 5.1 represents redirected native stderr as ErrorRecord objects.
        # Continue is local to this function; retain the native exit code too.
        $ErrorActionPreference = 'Continue'
        $captured = @(& $GitPath @GitArguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    $stdout = @($captured | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { [string]$_ })
    $stderr = @($captured | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { [string]$_ })
    [pscustomobject]@{ Code = $code; Stdout = $stdout; Stderr = $stderr }
}

function Get-GitCheck {
    param([string]$Directory)
    try {
        $git = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $git) { return (New-Check 'git-clean' 'unknown' 'git unavailable') }
        $top = Invoke-ReadOnlyGit $git.Source @('--no-optional-locks', '-C', $Directory,
            'rev-parse', '--show-toplevel')
        if ($top.Code -ne 0 -or $top.Stdout.Count -ne 1) {
            return (New-Check 'git-clean' 'unknown' 'repository top-level unavailable')
        }
        $topPath = Get-AbsolutePath $top.Stdout[0]
        $trimChars = [char[]]@('\', '/')
        if (-not [string]::Equals($topPath.TrimEnd($trimChars),
            $Directory.TrimEnd($trimChars), [System.StringComparison]::OrdinalIgnoreCase)) {
            return (New-Check 'git-clean' 'unknown' 'repository top-level differs from SkillDir')
        }
        $state = Invoke-ReadOnlyGit $git.Source @('--no-optional-locks', '-C', $Directory,
            'status', '--porcelain', '--untracked-files=all')
        if ($state.Code -ne 0) {
            return (New-Check 'git-clean' 'unknown' 'git status failed')
        }
        if ($state.Stdout.Count -gt 0) {
            return (New-Check 'git-clean' 'fail' ([string]$state.Stdout.Count))
        }
        return (New-Check 'git-clean' 'pass' '')
    }
    catch { return (New-Check 'git-clean' 'unknown' 'git command failed') }
}

function Get-RequiredFilesCheck {
    param([string]$Directory, [string]$Name, [string[]]$Files)
    $missing = @()
    foreach ($relative in $Files) {
        if ((Get-PathKind ([System.IO.Path]::Combine($Directory, $relative))) -ne 'file') {
            $missing += $relative
        }
    }
    if ($missing.Count -gt 0) { return (New-Check $Name 'fail' ($missing -join ',')) }
    return (New-Check $Name 'pass' '')
}

try {
    if ($null -eq $SkillDir -and -not $PSBoundParameters.ContainsKey('SkillDir')) {
        $SkillDir = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
    }
    if ($SkillDir -isnot [string] -or [string]::IsNullOrWhiteSpace($SkillDir)) {
        Stop-Usage 'SkillDir must be a nonempty string'
    }
    if ($args.Count -gt 0) { Stop-Usage 'only SkillDir is supported' }
    $SkillDir = Get-AbsolutePath $SkillDir
    if ((Get-PathKind $SkillDir) -ne 'directory') {
        Stop-Usage 'SkillDir must be an existing directory'
    }

    $checks = @()
    $marker = [System.IO.Path]::Combine($SkillDir, '.tiaokong-dev')
    if ((Get-PathKind $marker) -eq 'missing') {
        $checks += New-Check 'dev-marker' 'pass' ''
    }
    else { $checks += New-Check 'dev-marker' 'fail' 'development repository' }

    $versionPath = [System.IO.Path]::Combine($SkillDir, 'VERSION')
    $changelogPath = [System.IO.Path]::Combine($SkillDir, 'CHANGELOG.md')
    $versionKind = Get-PathKind $versionPath
    $changelogKind = Get-PathKind $changelogPath
    if ($versionKind -eq 'directory' -or $changelogKind -eq 'directory') {
        Stop-Usage 'VERSION and CHANGELOG.md must be files'
    }
    $version = 'missing'
    $changelogVersion = 'missing'
    $validVersion = $false
    if ($versionKind -eq 'file') {
        $versionText = Read-StrictUtf8 $versionPath
        $version = ([regex]::Split($versionText, '\r\n|\r|\n'))[0].Trim()
        $validVersion = $version -cmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z'
        if ($version.Length -eq 0) { $version = 'empty' }
    }
    if ($changelogKind -eq 'file') {
        $changelogText = Read-StrictUtf8 $changelogPath
        $changelogVersion = 'no version in first heading'
        foreach ($line in [regex]::Split($changelogText, '\r\n|\r|\n')) {
            if ($line.StartsWith('## ', [System.StringComparison]::Ordinal)) {
                $match = [regex]::Match($line.Substring(3),
                    '(?<![0-9.])[0-9]+\.[0-9]+\.[0-9]+(?![0-9.])')
                if ($match.Success) { $changelogVersion = $match.Value }
                break
            }
        }
    }
    if ($validVersion -and $version -ceq $changelogVersion) {
        $checks += New-Check 'version' 'pass' $version
    }
    else {
        $checks += New-Check 'version' 'fail' ("VERSION=$version, CHANGELOG=$changelogVersion")
    }

    $checks += Get-GitCheck $SkillDir
    $checks += Get-RequiredFilesCheck $SkillDir 'steps' @(
        'steps/new-binding.md', 'steps/lock-conflict.md',
        'steps/full-research.md', 'steps/model-failure.md')
    $checks += Get-RequiredFilesCheck $SkillDir 'control-scripts' @(
        'scripts/control/bind.ps1', 'scripts/control/lock.ps1',
        'scripts/control/read-section.ps1', 'scripts/control/stage-commit.ps1',
        'scripts/control/self-check.ps1')

    $overall = 'pass'
    $exitCode = 0
    if (@($checks | Where-Object { $_.Status -eq 'fail' }).Count -gt 0) {
        $overall = 'fail'
        $exitCode = 1
    }
    $output = @("status=$overall")
    foreach ($check in $checks) {
        $detail = ($check.Detail -replace '\r\n|\r|\n', ' ').Replace(';', ',')
        $output += "check=$($check.Name);status=$($check.Status);detail=$detail"
    }
    $output += "status=$overall"
    $output | ForEach-Object { [Console]::WriteLine($_) }
    exit $exitCode
}
catch {
    $message = $_.Exception.Message -replace '\r\n|\r|\n', ' '
    if ($_.Exception.Data.Contains('self-check-usage')) {
        [Console]::WriteLine('status=usage')
        [Console]::WriteLine("message=$message")
        exit 2
    }
    [Console]::WriteLine('status=error')
    [Console]::WriteLine("message=$message")
    exit 3
}
