param(
    [string]$Action = '',
    [string]$LockPath = '',
    [string]$Id = '',
    [string]$Task = '',
    [string]$Retry = '0',
    [string]$WaitSec = '10',
    [string]$File = '',
    [string]$ExpectHash = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

$explicitId = $PSBoundParameters.ContainsKey('Id')
$script:UsageMessage = $null
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

function Stop-Usage([string]$Message) {
    $script:UsageMessage = $Message
    throw (New-Object System.ArgumentException($Message))
}

function New-Result([string]$Status, [int]$Code, $Fields) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('status=' + $Status)
    if ($null -ne $Fields) {
        foreach ($key in $Fields.Keys) {
            $value = [regex]::Replace([string]$Fields[$key], '\r\n|\r|\n', ' ')
            $lines.Add([string]$key + '=' + $value)
        }
    }
    return [pscustomobject]@{ Code = $Code; Lines = $lines.ToArray() }
}

function Get-AbsoluteFilePath([string]$Value, [string]$Name) {
    if ([string]::IsNullOrEmpty($Value)) { Stop-Usage ($Name + ' is required') }
    $windows = $Value.Replace('/', '\')
    if ($windows -match '^[a-zA-Z]:\\') {
        $tail = $windows.Substring(2)
    }
    elseif ($windows -match '^\\\\[^\\]+\\[^\\]+(?:\\|$)') {
        # Device namespaces are not ordinary UNC server/share paths.
        $parts = $windows.Substring(2).Split([char]'\')
        if ($parts[0] -eq '.' -or $parts[0] -eq '?' -or
            $parts[0] -eq '..' -or $parts[1] -eq '.' -or $parts[1] -eq '..') {
            Stop-Usage ($Name + ' must be an absolute Windows file path')
        }
        $tail = $windows
    }
    else { Stop-Usage ($Name + ' must be an absolute Windows file path') }
    if ($tail -match '[<>:"|?*\x00-\x1f]') {
        Stop-Usage ($Name + ' contains invalid path characters')
    }
    try { $full = [System.IO.Path]::GetFullPath($windows) }
    catch { Stop-Usage ($Name + ' must be a valid Windows file path') }
    if ([string]::IsNullOrEmpty([System.IO.Path]::GetFileName($full))) {
        Stop-Usage ($Name + ' must name a file')
    }
    return $full
}

function Get-PathKind([string]$Path) {
    try { $attributes = [System.IO.File]::GetAttributes($Path) }
    catch {
        $cause = $_.Exception.GetBaseException()
        if ($cause -is [System.IO.FileNotFoundException] -or
            $cause -is [System.IO.DirectoryNotFoundException]) { return 'missing' }
        throw
    }
    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) { return 'directory' }
    return 'file'
}

function Read-Lock([string]$Path) {
    # Unreadable existing markers are deliberately lock-empty, not error.
    try { $kind = Get-PathKind $Path }
    catch { return [pscustomobject]@{ State = 'lock-empty' } }
    if ($kind -eq 'directory') { Stop-Usage 'LockPath must name a file' }
    if ($kind -eq 'missing') { return [pscustomobject]@{ State = 'lock-missing' } }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $text = $strictUtf8.GetString($bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xfeff) { $text = $text.Substring(1) }
    }
    catch { return [pscustomobject]@{ State = 'lock-empty' } }

    $holderId = ''
    $started = ''
    $lockTask = ''
    $idCount = 0
    $hasStarted = $false
    $hasTask = $false
    foreach ($line in [regex]::Split($text, '\r\n|\r|\n')) {
        if ($line.StartsWith('id=', [System.StringComparison]::Ordinal)) {
            $idCount++
            $holderId = $line.Substring(3)
        }
        elseif (-not $hasStarted -and $line.StartsWith('started=', [System.StringComparison]::Ordinal)) {
            $started = $line.Substring(8)
            $hasStarted = $true
        }
        elseif (-not $hasTask -and $line.StartsWith('task=', [System.StringComparison]::Ordinal)) {
            $lockTask = $line.Substring(5)
            $hasTask = $true
        }
    }
    if ($idCount -ne 1 -or [string]::IsNullOrEmpty($holderId)) {
        return [pscustomobject]@{ State = 'lock-empty' }
    }
    return [pscustomobject]@{ State = 'held'; Id = $holderId; Started = $started; Task = $lockTask }
}

function Get-LockResult($Lock, [string]$OwnerId, [bool]$MayOwn) {
    if ($Lock.State -ne 'held') { return (New-Result $Lock.State 1 $null) }
    if ($MayOwn -and [string]::Equals($Lock.Id, $OwnerId, [System.StringComparison]::Ordinal)) {
        return (New-Result 'held-by-self' 0 ([ordered]@{ id = $OwnerId }))
    }
    $age = ''
    $time = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse($Lock.Started, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$time)) {
        $minutes = [long][Math]::Truncate(([System.DateTimeOffset]::Now - $time).TotalMinutes)
        $age = $minutes.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    $prefix = $Lock.Id.Substring(0, [Math]::Min(8, $Lock.Id.Length))
    return (New-Result 'held-by-other' 1 ([ordered]@{
        holder_id8 = $prefix; started = $Lock.Started; age_minutes = $age; task = $Lock.Task
    }))
}

function Test-NameCollision($Exception) {
    $cause = $Exception.GetBaseException()
    $nativeCode = $cause.HResult -band 0xffff
    return ($cause -is [System.IO.IOException] -and ($nativeCode -eq 80 -or $nativeCode -eq 183))
}

function New-LockFile([string]$Path, [string]$OwnerId, [string]$Description) {
    $started = [System.DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)
    $singleTask = [regex]::Replace($Description, '\r\n|\r|\n', ' ')
    $body = 'id=' + $OwnerId + "`nstarted=" + $started + "`ntask=" + $singleTask + "`n"
    $bytes = $strictUtf8.GetBytes($body)
    $temporary = $null
    $stream = $null
    $owned = $false
    try {
        for ($collision = 0; $collision -lt 10; $collision++) {
            $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $candidate = $Path + '.' + $suffix + '.tmp'
            try {
                $stream = [System.IO.File]::Open($candidate, [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $temporary = $candidate
                $owned = $true
                break
            }
            catch {
                if (-not (Test-NameCollision $_.Exception)) { throw }
            }
        }
        if (-not $owned) { throw (New-Object System.IO.IOException('Temporary filename collisions exhausted')) }
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $stream.Dispose()
        $stream = $null
        try {
            # File.Move on .NET Framework never overwrites the destination.
            [System.IO.File]::Move($temporary, $Path)
            $owned = $false
            return $true
        }
        catch {
            if (Test-NameCollision $_.Exception) { return $false }
            throw
        }
    }
    finally {
        try { if ($null -ne $stream) { $stream.Dispose() } }
        finally { if ($owned) { [System.IO.File]::Delete($temporary) } }
    }
}

function Get-FileHashResult([string]$Path) {
    $kind = Get-PathKind $Path
    if ($kind -eq 'directory') { Stop-Usage 'File must name a file' }
    if ($kind -eq 'missing') { return [pscustomobject]@{ Exists = $false; Hash = '' } }
    $stream = $null
    $sha = $null
    try {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        }
        catch {
            $cause = $_.Exception.GetBaseException()
            if ($cause -is [System.IO.FileNotFoundException] -or
                $cause -is [System.IO.DirectoryNotFoundException]) {
                return [pscustomobject]@{ Exists = $false; Hash = '' }
            }
            throw
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $digest = $sha.ComputeHash($stream)
        $hex = [System.BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()
        return [pscustomobject]@{ Exists = $true; Hash = $hex }
    }
    finally {
        try { if ($null -ne $sha) { $sha.Dispose() } }
        finally { if ($null -ne $stream) { $stream.Dispose() } }
    }
}

try {
    $actionName = $Action.ToLowerInvariant()
    if (@('acquire', 'check', 'release', 'hash', 'guard') -notcontains $actionName) {
        Stop-Usage 'Action must be acquire, check, release, hash or guard'
    }
    $retryCount = 0
    $waitSeconds = 0
    if (-not [int]::TryParse($Retry, [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$retryCount) -or
        $retryCount -lt 0 -or $retryCount -gt 10) { Stop-Usage 'Retry must be an integer from 0 to 10' }
    if (-not [int]::TryParse($WaitSec, [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$waitSeconds) -or
        $waitSeconds -lt 0 -or $waitSeconds -gt 60) { Stop-Usage 'WaitSec must be an integer from 0 to 60' }

    if ($actionName -ne 'hash') {
        $lockFull = Get-AbsoluteFilePath $LockPath 'LockPath'
        if (($actionName -ne 'acquire' -or $explicitId) -and [string]::IsNullOrEmpty($Id)) {
            Stop-Usage 'Id is required'
        }
        if ($Id -match '[\r\n]') { Stop-Usage 'Id must not contain a newline' }
    }
    if ($actionName -eq 'acquire' -and [string]::IsNullOrEmpty($Task)) { Stop-Usage 'Task is required' }
    if ($actionName -eq 'hash' -or $actionName -eq 'guard') {
        $fileFull = Get-AbsoluteFilePath $File 'File'
    }
    if ($actionName -eq 'guard' -and $ExpectHash -notmatch '\A(?:none|[0-9a-f]{64})\z') {
        Stop-Usage 'ExpectHash must be none or 64 hexadecimal characters'
    }
    if ($actionName -eq 'guard' -and (Get-PathKind $fileFull) -eq 'directory') {
        Stop-Usage 'File must name a file'
    }

    if ($actionName -eq 'acquire') {
        $parent = [System.IO.Path]::GetDirectoryName($lockFull)
        $parentKind = Get-PathKind $parent
        if ($parentKind -eq 'missing') { Stop-Usage 'lock directory missing' }
        if ($parentKind -ne 'directory') { Stop-Usage 'lock parent must be a directory' }
        if (-not $explicitId) { $Id = [Guid]::NewGuid().ToString() }
        for ($attempt = 1; $attempt -le ($retryCount + 1); $attempt++) {
            $lock = Read-Lock $lockFull
            if ($lock.State -eq 'lock-missing') {
                if (New-LockFile $lockFull $Id $Task) {
                    $result = New-Result 'acquired' 0 ([ordered]@{ id = $Id })
                    break
                }
                $lock = Read-Lock $lockFull
                # A competing marker may disappear before it can be read.
                # Acquire never reports lock-missing; retry this unavailable marker.
                if ($lock.State -eq 'lock-missing') { $lock = [pscustomobject]@{ State = 'lock-empty' } }
            }
            $result = Get-LockResult $lock $Id $explicitId
            if ($result.Code -eq 0) { break }
            if ($attempt -le $retryCount) {
                if ($waitSeconds -gt 0) { Start-Sleep -Seconds $waitSeconds }
            }
            elseif ($retryCount -gt 0) {
                $result.Lines = @($result.Lines) + ('attempts=' + $attempt.ToString([System.Globalization.CultureInfo]::InvariantCulture))
            }
        }
    }
    elseif ($actionName -eq 'hash') {
        $fileState = Get-FileHashResult $fileFull
        if ($fileState.Exists) { $result = New-Result 'ok' 0 ([ordered]@{ hash = $fileState.Hash }) }
        else { $result = New-Result 'file-missing' 1 $null }
    }
    else {
        $lock = Read-Lock $lockFull
        $result = Get-LockResult $lock $Id $true
        if ($result.Code -eq 0) {
            if ($actionName -eq 'release') {
                # Cooperative ownership check, not a transaction against hostile replacement.
                [System.IO.File]::Delete($lockFull)
                $result = New-Result 'released' 0 $null
            }
            elseif ($actionName -eq 'guard') {
                $fileState = Get-FileHashResult $fileFull
                $same = (($ExpectHash -ieq 'none') -and -not $fileState.Exists) -or
                    (($ExpectHash -ine 'none') -and $fileState.Exists -and ($ExpectHash -ieq $fileState.Hash))
                if ($same) { $result = New-Result 'ok' 0 $null }
                else { $result = New-Result 'file-changed' 1 ([ordered]@{ current_hash = $fileState.Hash }) }
            }
        }
    }
}
catch {
    if ($null -ne $script:UsageMessage) {
        $result = New-Result 'usage' 2 ([ordered]@{ message = $script:UsageMessage })
    }
    else {
        $result = New-Result 'error' 3 ([ordered]@{ message = $_.Exception.GetBaseException().Message })
    }
}

# Nothing is emitted until operations and owned-temporary cleanup have finished.
foreach ($line in $result.Lines) { [Console]::WriteLine($line) }
exit $result.Code
