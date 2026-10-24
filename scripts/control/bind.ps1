param(
    [string]$Action,
    [string]$WorkDir,
    [string]$ConfigRoot = (Join-Path $HOME '.config/opencode'),
    [string]$SkillDir = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$ProfilePath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Stop-Usage([string]$Message) {
    $exception = New-Object System.ArgumentException($Message)
    $exception.Data['bind_usage'] = $true
    throw $exception
}

function Get-WindowsPath([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value)) { Stop-Usage "$Name is required" }
    $path = $Value.Replace('/', '\')
    if ($path -match '[\x00-\x1f<>"|?*]' -or
        $path.StartsWith('\\.\', [StringComparison]::Ordinal) -or
        $path.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        Stop-Usage "$Name must be a Windows absolute filesystem path"
    }
    if ($path -match '^[A-Za-z]:\\') {
        if ($path.Substring(2).Contains(':')) { Stop-Usage "$Name must not contain an alternate data stream" }
    }
    elseif ($path -match '^\\\\[^\\]+\\[^\\]+(?:\\|$)') {
        if ($path.Contains(':')) { Stop-Usage "$Name must not contain an alternate data stream" }
        $parts = $path.Substring(2).Split([char]'\')
        if ($parts[0] -in @('.', '..', '?') -or $parts[1] -in @('.', '..')) {
            Stop-Usage "$Name must be a Windows absolute filesystem path"
        }
    }
    else { Stop-Usage "$Name must be a Windows absolute filesystem path" }
    $segments = $path -split '\\'
    $firstSegment = 1
    if ($path.StartsWith('\\', [StringComparison]::Ordinal)) { $firstSegment = 4 }
    for ($index = $firstSegment; $index -lt $segments.Count; $index++) {
        if ($segments[$index].TrimEnd(' ', '.') -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            Stop-Usage "$Name must not contain a device name"
        }
    }
    try { return [IO.Path]::GetFullPath($path) }
    catch [System.ArgumentException] { Stop-Usage "$Name is not a valid filesystem path" }
    catch [System.NotSupportedException] { Stop-Usage "$Name is not a valid filesystem path" }
    catch [System.IO.PathTooLongException] { Stop-Usage "$Name is too long" }
}

function Test-DotDot([string]$Value) {
    return [bool]($Value -match '(^|[\\/])\.\.([\\/]|$)')
}

function Get-EntryKind([string]$Path) {
    try {
        $attributes = [IO.File]::GetAttributes($Path)
        if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { return 'directory' }
        return 'file'
    }
    catch [IO.FileNotFoundException] { return 'missing' }
    catch [IO.DirectoryNotFoundException] { return 'missing' }
}

function Assert-DirectoryType([string]$Path, [string]$Name, [bool]$Required) {
    $kind = Get-EntryKind $Path
    if ($kind -eq 'file' -or ($Required -and $kind -eq 'missing')) {
        Stop-Usage "$Name must be an existing directory"
    }
    return $kind
}

function Test-InDirectory([string]$Path, [string]$Directory) {
    $base = $Directory.TrimEnd([char[]]@('\', '/'))
    return ($Path.Equals($base, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Get-LocationReason([string]$Path, [string]$Skill, [string]$Registry, [string]$Projects, [string]$Project) {
    if (Test-InDirectory $Path $Skill) { return 'skill-dir' }
    if (Test-InDirectory $Path $Registry) { return 'registry' }
    if ((Test-InDirectory $Path $Projects) -and -not (Test-InDirectory $Path $Project)) {
        return 'other-project'
    }
    return ''
}

function Read-Utf8([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $offset = 3
    }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    return $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
}

function Get-LogicalLines([string]$Text) {
    return [regex]::Split($Text, '\r\n|\n|\r')
}

function Test-Collision([System.Exception]$Exception) {
    # PowerShell method invocation wrappers can retain the native exception as an inner exception.
    while ($null -ne $Exception) {
        if ($Exception -is [IO.IOException]) {
            $nativeCode = $Exception.HResult -band 65535
            if ($nativeCode -eq 80 -or $nativeCode -eq 183) { return $true }
        }
        $Exception = $Exception.InnerException
    }
    return $false
}

function Write-NewRegistry([string]$Target, [string]$Text) {
    $kind = Get-EntryKind $Target
    if ($kind -eq 'directory') { Stop-Usage 'registry_file must be a file' }
    if ($kind -eq 'file') { return 'exists' }
    $temporary = $null
    $ownsTemporary = $false
    try {
        $stream = $null
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $candidate = $Target + '.' + $suffix + '.tmp'
            try {
                $stream = [IO.File]::Open($candidate, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $temporary = $candidate
                $ownsTemporary = $true
                break
            }
            catch [IO.IOException] {
                if (-not (Test-Collision $_.Exception)) { throw }
                if ($attempt -eq 9) { throw }
            }
        }
        try {
            $encoding = New-Object System.Text.UTF8Encoding($false)
            $bytes = $encoding.GetBytes($Text)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        }
        finally { if ($null -ne $stream) { $stream.Dispose() } }
        try {
            [IO.File]::Move($temporary, $Target)
            $ownsTemporary = $false
            return 'written'
        }
        catch [IO.IOException] {
            if ((Test-Collision $_.Exception) -and (Get-EntryKind $Target) -eq 'file') {
                return 'exists'
            }
            throw
        }
    }
    finally {
        if ($ownsTemporary) { [IO.File]::Delete($temporary) }
    }
}

function Invoke-Bind {
    if ($Action -cnotin @('info', 'check-profile', 'write-registry')) {
        Stop-Usage 'Action must be info, check-profile, or write-registry'
    }
    # Validate the supplied directory, but never substitute its full path in the identity algorithm.
    $workFull = Get-WindowsPath $WorkDir 'WorkDir'
    $configFull = Get-WindowsPath $ConfigRoot 'ConfigRoot'
    $skillFull = Get-WindowsPath $SkillDir 'SkillDir'
    $profileFull = ''
    $profileDotDot = $false
    if ($Action -ne 'info') {
        if ([string]::IsNullOrWhiteSpace($ProfilePath)) { Stop-Usage 'ProfilePath is required' }
        $profileDotDot = Test-DotDot $ProfilePath
        if (-not $profileDotDot) { $profileFull = Get-WindowsPath $ProfilePath 'ProfilePath' }
    }
    $null = Assert-DirectoryType $WorkDir 'WorkDir' $true
    $configKind = Assert-DirectoryType $configFull 'ConfigRoot' $false
    $null = Assert-DirectoryType $skillFull 'SkillDir' $false

    $normalized = $WorkDir.TrimEnd([char[]]@('\', '/')).Replace('\', '/').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $registryName = [BitConverter]::ToString($sha.ComputeHash($encoding.GetBytes($normalized))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
    $lastName = ($normalized -split '/')[-1]
    $slug = [regex]::Replace($lastName, '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 24) { $slug = $slug.Substring(0, 24).TrimEnd('-') }
    if ($slug.Length -eq 0) { $slug = 'p' }
    $projectId = $slug + '-' + $registryName.Substring(0, 6)
    $registryDirectory = [IO.Path]::GetFullPath([IO.Path]::Combine($configFull, 'tiaokong-registry'))
    $projectsDirectory = [IO.Path]::GetFullPath([IO.Path]::Combine($configFull, 'tiaokong-projects'))
    $registryFile = [IO.Path]::GetFullPath([IO.Path]::Combine($registryDirectory, $registryName + '.md'))
    $projectDirectory = [IO.Path]::GetFullPath([IO.Path]::Combine($projectsDirectory, $projectId))

    if ($Action -ne 'info') {
        $reason = ''
        if ($profileDotDot) { $reason = 'dotdot' }
        else { $reason = Get-LocationReason $profileFull $skillFull $registryDirectory $projectsDirectory $projectDirectory }
        if ($reason.Length -gt 0) {
            return @{ Lines = @('status=rejected', ('full_path=' + $profileFull), ('reason=' + $reason)); Code = 1 }
        }
        if ((Get-EntryKind $profileFull) -eq 'directory' -or
            $profileFull.Equals($projectDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Usage 'ProfilePath must be a file path'
        }
        if ($ProfilePath.EndsWith('\') -or $ProfilePath.EndsWith('/')) { Stop-Usage 'ProfilePath must be a file path' }
        if ($Action -eq 'check-profile') {
            return @{ Lines = @('status=ok', ('full_path=' + $profileFull)); Code = 0 }
        }
        if ($configKind -eq 'missing') { throw (New-Object IO.DirectoryNotFoundException('ConfigRoot does not exist')) }
        $null = Assert-DirectoryType $registryDirectory 'registry directory' $false
        $null = [IO.Directory]::CreateDirectory($registryDirectory)
        if ((Get-EntryKind $registryDirectory) -ne 'directory') { throw 'Registry directory creation failed' }
        $text = $normalized + "`n" + $projectId + "`n" + $profileFull + "`n"
        $status = Write-NewRegistry $registryFile $text
        $code = 0
        if ($status -eq 'exists') { $code = 1 }
        return @{ Lines = @(('status=' + $status), ('registry_file=' + $registryFile), ('project_id=' + $projectId)); Code = $code }
    }

    $status = ''
    $code = 1
    $extra = @()
    $registered = $false
    $registryProjectId = ''
    $registeredProfile = ''
    $marker = [IO.Path]::Combine($WorkDir, '.tiaokong-dev')
    $skillFile = [IO.Path]::Combine($WorkDir, 'SKILL.md')
    if ((Get-EntryKind $marker) -ne 'missing') { $status = 'skill-repo' }
    else {
        $skillKind = Get-EntryKind $skillFile
        if ($skillKind -eq 'directory') { Stop-Usage 'SKILL.md must be a file' }
        if ($skillKind -eq 'file') {
            foreach ($line in (Get-LogicalLines (Read-Utf8 $skillFile))) {
                if ($line -ceq 'name: tiaokong') { $status = 'skill-repo'; break }
            }
        }
    }
    if ($status.Length -eq 0) {
        $registryKind = Get-EntryKind $registryFile
        if ($registryKind -eq 'directory') { Stop-Usage 'registry_file must be a file' }
        if ($registryKind -eq 'missing') { $status = 'not-bound'; $code = 0 }
        else {
            $registered = $true
            $lines = @(Get-LogicalLines (Read-Utf8 $registryFile) | ForEach-Object { $_.Trim() })
            $count = $lines.Count
            while ($count -gt 0 -and $lines[$count - 1].Length -eq 0) { $count-- }
            if ($count -gt 1) { $registryProjectId = $lines[1] }
            if ($count -gt 2) { $registeredProfile = $lines[2] }
            if ($count -ne 3) { $status = 'registry-bad'; $extra = @('registry_lines=' + $count) }
            elseif ($lines[0] -cne $normalized) { $status = 'registry-mismatch'; $extra = @('registry_dir=' + $lines[0]) }
            elseif ($registryProjectId -cne $projectId) {
                $status = 'registry-bad'; $extra = @('registry_lines=3', 'reason=project-id')
            }
            else {
                $pathInvalid = $false
                try {
                    $registeredFull = Get-WindowsPath $registeredProfile 'registered profile'
                    if ($registeredProfile.EndsWith('\') -or $registeredProfile.EndsWith('/')) { $pathInvalid = $true }
                }
                catch {
                    if ($_.Exception.Data.Contains('bind_usage')) { $pathInvalid = $true }
                    else { throw }
                }
                if ($pathInvalid) { $status = 'registry-bad'; $extra = @('registry_lines=3', 'reason=profile-path') }
                elseif ((Test-DotDot $registeredProfile) -or
                    (Get-LocationReason $registeredFull $skillFull $registryDirectory $projectsDirectory $projectDirectory).Length -gt 0) {
                    $status = 'registry-bad'; $extra = @('registry_lines=3', 'reason=profile-location')
                }
                else {
                    # Do not access the registered profile until all identity and location checks pass.
                    $profileKind = Get-EntryKind $registeredFull
                    if ($profileKind -eq 'directory' -or $registeredFull.Equals($projectDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                        $status = 'registry-bad'; $extra = @('registry_lines=3', 'reason=profile-path')
                    }
                    elseif ($profileKind -eq 'missing') { $status = 'profile-missing' }
                    else {
                        $hasSection = $false
                        foreach ($line in (Get-LogicalLines (Read-Utf8 $registeredFull))) {
                            if ($line -ceq '## 启用要点') { $hasSection = $true; break }
                        }
                        if ($hasSection) { $status = 'ok'; $code = 0 }
                        else { $status = 'profile-no-section' }
                    }
                }
            }
        }
    }
    $output = @(('status=' + $status), ('normalized=' + $normalized), ('registry_name=' + $registryName),
        ('project_id=' + $projectId), ('registry_file=' + $registryFile), ('project_dir=' + $projectDirectory))
    if ($registered) { $output += @(('registry_project_id=' + $registryProjectId), ('profile_path=' + $registeredProfile)) }
    $output += $extra
    return @{ Lines = $output; Code = $code }
}

try {
    $result = Invoke-Bind
    $buffer = @($result.Lines | ForEach-Object { [regex]::Replace([string]$_, '\r\n|\r|\n', ' ') })
    $exitCode = $result.Code
}
catch {
    $status = 'error'
    $exitCode = 3
    if ($_.Exception.Data.Contains('bind_usage')) { $status = 'usage'; $exitCode = 2 }
    $message = [regex]::Replace($_.Exception.Message, '\r\n|\r|\n', ' ')
    $buffer = @(('status=' + $status), ('message=' + $message))
}
foreach ($line in $buffer) { [Console]::WriteLine($line) }
exit $exitCode
