param(
    [string]$Action,
    [string]$File,
    [string]$Headings,
    [string]$Match
)

$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = [Console]::OutputEncoding

    function Stop-Usage {
        param([string]$Message)
        [Console]::WriteLine('status=usage')
        [Console]::WriteLine('message=' + $Message)
        exit 2
    }

    function ConvertTo-Field {
        param([string]$Value)
        return $Value.Replace("`r`n", ' ').Replace("`r", ' ').Replace("`n", ' ')
    }

    # Validate the complete request before accessing the input file.
    if ([string]::IsNullOrEmpty($Action) -or [string]::IsNullOrEmpty($File)) {
        Stop-Usage 'Action and File are required.'
    }
    if (@('headings', 'section', 'lines', 'stage') -cnotcontains $Action) {
        Stop-Usage 'Unknown action.'
    }

    $requested = @()
    $terms = @()
    if ($Action -ceq 'section') {
        if ([string]::IsNullOrEmpty($Headings)) {
            Stop-Usage 'Headings is required for section.'
        }
        $requested = $Headings.Split([char]'|')
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($title in $requested) {
            if ($title.Length -eq 0 -or -not $seen.Add($title)) {
                Stop-Usage 'Headings must contain nonempty unique titles.'
            }
        }
    }
    if ($Action -ceq 'lines') {
        if ([string]::IsNullOrEmpty($Match)) {
            Stop-Usage 'Match is required for lines.'
        }
        $terms = $Match.Split([char]'|')
        foreach ($term in $terms) {
            if ($term.Length -eq 0) {
                Stop-Usage 'Match must contain nonempty terms.'
            }
        }
    }

    # Accept only drive-rooted or server/share UNC Windows paths.
    $windowsPath = $File.Replace('/', '\')
    if ($windowsPath.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $windowsPath.StartsWith('\\.\', [StringComparison]::Ordinal)) {
        Stop-Usage 'File must be an absolute filesystem path.'
    }
    $drivePath = $windowsPath -cmatch '^[A-Za-z]:\\'
    $uncPath = $windowsPath -cmatch '^\\\\[^\\]+\\[^\\]+(?:\\|$)'
    if (-not $drivePath -and -not $uncPath) {
        Stop-Usage 'File must be an absolute filesystem path.'
    }
    $pathTail = $windowsPath
    if ($drivePath) {
        $pathTail = $windowsPath.Substring(2)
    }
    if ($pathTail.IndexOf(':') -ge 0 -or
        $windowsPath.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or
        $windowsPath.IndexOfAny([char[]]'*?"<>|') -ge 0) {
        Stop-Usage 'File contains invalid path characters or an alternate data stream.'
    }
    if ($uncPath) {
        $uncParts = $windowsPath.Substring(2).Split([char]'\')
        if ($uncParts[0] -eq '.' -or $uncParts[0] -eq '..' -or
            $uncParts[1] -eq '.' -or $uncParts[1] -eq '..') {
            Stop-Usage 'File must be an absolute filesystem path.'
        }
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($windowsPath)
    }
    catch [ArgumentException] {
        Stop-Usage 'File is not a valid filesystem path.'
    }
    catch [NotSupportedException] {
        Stop-Usage 'File is not a valid filesystem path.'
    }
    catch [IO.PathTooLongException] {
        Stop-Usage 'File is not a valid filesystem path.'
    }

    $missingFile = $false
    try {
        $attributes = [IO.File]::GetAttributes($fullPath)
        if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            Stop-Usage 'File must be a file, not a directory.'
        }
    }
    catch [IO.FileNotFoundException] {
        $missingFile = $true
    }
    catch [IO.DirectoryNotFoundException] {
        $missingFile = $true
    }

    $outputLines = New-Object 'System.Collections.Generic.List[string]'
    $exitCode = 0
    if ($missingFile) {
        $outputLines.Add('status=file-missing')
        $exitCode = 1
    }
    else {
        $bytes = [IO.File]::ReadAllBytes($fullPath)
        $offset = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
            $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $offset = 3
        }
        $decoder = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $decoder.GetString($bytes, $offset, $bytes.Length - $offset)
        $logicalLines = @()
        if ($text.Length -gt 0) {
            $logicalLines = [regex]::Split($text, "`r`n|`n|`r")
            if ($text.EndsWith("`n", [StringComparison]::Ordinal) -or
                $text.EndsWith("`r", [StringComparison]::Ordinal)) {
                $logicalLines = @($logicalLines[0..($logicalLines.Length - 2)])
            }
        }

        $outputLines.Add('status=ok')
        switch -CaseSensitive ($Action) {
            'headings' {
                for ($i = 0; $i -lt $logicalLines.Length; $i++) {
                    if ($logicalLines[$i].StartsWith('## ', [StringComparison]::Ordinal)) {
                        $outputLines.Add('heading=' + ($i + 1) + ':' + $logicalLines[$i].Substring(3))
                    }
                }
            }
            'section' {
                $missingTitles = New-Object 'System.Collections.Generic.List[string]'
                foreach ($title in $requested) {
                    $start = -1
                    for ($i = 0; $i -lt $logicalLines.Length; $i++) {
                        if ([string]::Equals($logicalLines[$i], '## ' + $title, [StringComparison]::Ordinal)) {
                            $start = $i
                            break
                        }
                    }
                    if ($start -lt 0) {
                        $missingTitles.Add($title)
                        continue
                    }
                    $outputLines.Add('begin=' + (ConvertTo-Field $title))
                    $outputLines.Add($logicalLines[$start])
                    for ($i = $start + 1; $i -lt $logicalLines.Length; $i++) {
                        if ($logicalLines[$i].StartsWith('## ', [StringComparison]::Ordinal)) {
                            break
                        }
                        $outputLines.Add($logicalLines[$i])
                    }
                    $outputLines.Add('end=' + (ConvertTo-Field $title))
                }
                if ($missingTitles.Count -gt 0) {
                    $outputLines[0] = 'status=partial'
                    $outputLines.Add('missing=' + (ConvertTo-Field ($missingTitles -join '|')))
                    $exitCode = 1
                }
            }
            'lines' {
                $matchingLines = New-Object 'System.Collections.Generic.List[string]'
                for ($i = 0; $i -lt $logicalLines.Length; $i++) {
                    foreach ($term in $terms) {
                        if ($logicalLines[$i].IndexOf($term, [StringComparison]::Ordinal) -ge 0) {
                            $matchingLines.Add('line=' + ($i + 1) + ':' + $logicalLines[$i])
                            break
                        }
                    }
                }
                $outputLines.Add('count=' + $matchingLines.Count)
                $outputLines.AddRange($matchingLines)
            }
            'stage' {
                foreach ($line in $logicalLines) {
                    if (-not $line.StartsWith('* ', [StringComparison]::Ordinal)) {
                        $outputLines.Add($line)
                    }
                }
            }
        }
    }

    # No successful protocol is emitted until reading and computation finish.
    foreach ($outputLine in $outputLines) {
        [Console]::WriteLine($outputLine)
    }
    exit $exitCode
}
catch {
    $message = $_.Exception.Message.Replace("`r`n", ' ').Replace("`r", ' ').Replace("`n", ' ')
    [Console]::WriteLine('status=error')
    [Console]::WriteLine('message=' + $message)
    exit 3
}
