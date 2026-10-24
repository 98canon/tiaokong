param(
    [string]$Action,
    [string]$File,
    [string]$Hash,
    [string]$Text
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

function Stop-Usage {
    param([string]$Message)

    $exception = New-Object System.ArgumentException($Message)
    $exception.Data['stage_commit_usage'] = $true
    throw $exception
}

function Get-AbsoluteFilePath {
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        Stop-Usage 'File is required.'
    }

    $path = $Value.Replace('/', '\')
    if ($path -cmatch '\A[A-Za-z]:\\') {
        $remainder = $path.Substring(3)
    }
    elseif ($path -cmatch '\A\\\\[^\\]+\\[^\\]+(?:\\|\z)') {
        $parts = $path.Substring(2).Split([char]'\')
        if ($parts[0] -eq '.' -or $parts[0] -eq '?' -or
            $parts[1] -eq '.' -or $parts[1] -eq '..') {
            Stop-Usage 'File must be an absolute Windows filesystem path.'
        }
        $remainder = $path.Substring(2)
    }
    else {
        Stop-Usage 'File must be an absolute Windows filesystem path.'
    }

    if ($remainder -match '[\x00-\x1f<>:"|?*]') {
        Stop-Usage 'File contains invalid Windows path characters.'
    }

    try {
        return [System.IO.Path]::GetFullPath($path)
    }
    catch [System.ArgumentException] {
        Stop-Usage 'File is not a valid Windows filesystem path.'
    }
    catch [System.NotSupportedException] {
        Stop-Usage 'File is not a valid Windows filesystem path.'
    }
    catch [System.IO.PathTooLongException] {
        Stop-Usage 'File is not a valid Windows filesystem path.'
    }
}

function New-Result {
    param([int]$Code, [string[]]$Lines)

    return [pscustomobject]@{ Code = $Code; Lines = $Lines }
}

function Write-AtomicReplacement {
    param([string]$Path, [byte[]]$Bytes)

    $ownedPath = $null
    $stream = $null
    try {
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $candidate = $Path + '.' + $suffix + '.tmp'
            try {
                $stream = [System.IO.File]::Open(
                    $candidate,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None
                )
                $ownedPath = $candidate
                break
            }
            catch [System.IO.IOException] {
                $ioException = $_.Exception
                while ($null -ne $ioException.InnerException) {
                    $ioException = $ioException.InnerException
                }
                $nativeCode = $ioException.HResult -band 65535
                if ($nativeCode -ne 80 -and $nativeCode -ne 183) {
                    throw
                }
            }
        }

        if ($null -eq $stream) {
            throw (New-Object System.IO.IOException('Temporary file name collisions exhausted ten attempts.'))
        }

        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        [System.IO.File]::Replace($ownedPath, $Path, [System.Management.Automation.Language.NullString]::Value)
        $ownedPath = $null
    }
    finally {
        if ($null -ne $ownedPath) {
            [System.IO.File]::Delete($ownedPath)
        }
    }
}

function Invoke-StageCommit {
    if ([string]::IsNullOrEmpty($Action) -or $Action -notin @('add', 'normalize', 'check')) {
        Stop-Usage 'Action must be add, normalize, or check.'
    }
    if ($Action -eq 'add') {
        if ([string]::IsNullOrEmpty($Hash) -or $Hash -cnotmatch '\A[0-9a-f]{7,40}\z') {
            Stop-Usage 'Hash must contain 7 to 40 lowercase hexadecimal characters.'
        }
        if ([string]::IsNullOrEmpty($Text) -or $Text.Contains("`r") -or $Text.Contains("`n")) {
            Stop-Usage 'Text must be nonempty and contain no CR or LF.'
        }
    }
    $fullPath = Get-AbsoluteFilePath $File

    try {
        $attributes = [System.IO.File]::GetAttributes($fullPath)
    }
    catch [System.IO.FileNotFoundException] {
        return (New-Result 1 @('status=file-missing'))
    }
    catch [System.IO.DirectoryNotFoundException] {
        return (New-Result 1 @('status=file-missing'))
    }
    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
        Stop-Usage 'File must refer to a file, not a directory.'
    }

    $originalBytes = [System.IO.File]::ReadAllBytes($fullPath)
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    $offset = 0
    if ($originalBytes.Length -ge 3 -and $originalBytes[0] -eq 239 -and
        $originalBytes[1] -eq 187 -and $originalBytes[2] -eq 191) {
        $offset = 3
    }
    $content = $encoding.GetString($originalBytes, $offset, $originalBytes.Length - $offset)
    $content = $content.Replace("`r`n", "`n")
    $hasFinalNewline = $content.EndsWith("`n", [System.StringComparison]::Ordinal)
    [string[]]$lines = $content.Split([char]10)
    $lineCount = $lines.Length
    if ($hasFinalNewline) {
        $lineCount--
    }

    $heading = -1
    for ($index = 0; $index -lt $lineCount; $index++) {
        if ($lines[$index].StartsWith('最近提交', [System.StringComparison]::Ordinal)) {
            $heading = $index
            break
        }
    }
    if ($heading -eq -1) {
        return (New-Result 1 @('status=no-commit-section'))
    }

    $start = $heading + 1
    while ($start -lt $lineCount -and $lines[$start].Length -eq 0) {
        $start++
    }
    $end = $start
    $rows = New-Object 'System.Collections.Generic.List[string]'
    while ($end -lt $lineCount) {
        $line = $lines[$end]
        if (-not ($line.StartsWith('- ', [System.StringComparison]::Ordinal) -or
            $line.StartsWith('* ', [System.StringComparison]::Ordinal))) {
            break
        }
        $rows.Add($line)
        $end++
    }

    if ($Action -eq 'check') {
        $dashCount = 0
        $starCount = 0
        $valid = $true
        for ($index = 0; $index -lt $rows.Count; $index++) {
            $isDash = $rows[$index].StartsWith('- ', [System.StringComparison]::Ordinal)
            if ($isDash) { $dashCount++ } else { $starCount++ }
            if ($isDash -ne ($index -lt 5)) { $valid = $false }
        }
        $status = 'ok'
        $code = 0
        if (-not $valid) { $status = 'bad'; $code = 1 }
        return (New-Result $code @("status=$status", "dash_count=$dashCount", "star_count=$starCount"))
    }

    if ($Action -eq 'add') {
        $rows.Insert(0, ('- `' + $Hash + '` ' + $Text))
    }
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $prefix = '* '
        if ($index -lt 5) { $prefix = '- ' }
        $rows[$index] = $prefix + $rows[$index].Substring(2)
    }

    $newLines = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt $start; $index++) {
        $newLines.Add($lines[$index])
    }
    $newLines.AddRange($rows)
    for ($index = $end; $index -lt $lineCount; $index++) {
        $newLines.Add($lines[$index])
    }
    $newContent = [string]::Join("`n", $newLines.ToArray())
    if ($hasFinalNewline) {
        $newContent += "`n"
    }
    $newBytes = $encoding.GetBytes($newContent)
    $changed = $newBytes.Length -ne $originalBytes.Length
    if (-not $changed) {
        for ($index = 0; $index -lt $newBytes.Length; $index++) {
            if ($newBytes[$index] -ne $originalBytes[$index]) {
                $changed = $true
                break
            }
        }
    }

    $dashCount = [Math]::Min(5, $rows.Count)
    $starCount = [Math]::Max(0, $rows.Count - 5)
    $output = New-Object 'System.Collections.Generic.List[string]'
    $output.Add('status=ok')
    $output.Add("dash_count=$dashCount")
    $output.Add("star_count=$starCount")
    for ($index = 0; $index -lt $dashCount; $index++) {
        $output.Add('top=' + [regex]::Replace($rows[$index], '\r\n|\r|\n', ' '))
    }
    $result = New-Result 0 $output.ToArray()
    if ($changed) {
        Write-AtomicReplacement $fullPath $newBytes
    }
    return $result
}

try {
    $result = Invoke-StageCommit
}
catch {
    $status = 'error'
    $code = 3
    if ($_.Exception.Data.Contains('stage_commit_usage')) {
        $status = 'usage'
        $code = 2
    }
    $message = [regex]::Replace($_.Exception.Message, '\r\n|\r|\n', ' ')
    $result = New-Result $code @("status=$status", "message=$message")
}

foreach ($line in $result.Lines) {
    [Console]::WriteLine($line)
}
exit $result.Code
