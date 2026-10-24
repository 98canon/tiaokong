param(
    [string]$TempRoot,
    [string]$ControlRoot
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# Black-box contract tests. Never read the control script, and never write outside
# this invocation's randomly named fixture directory.
$script:clock = [Diagnostics.Stopwatch]::StartNew()
$script:pass = 0
$script:fail = 0
$script:children = New-Object System.Collections.ArrayList
$script:ownedRoot = $null
$script:utf8 = New-Object Text.UTF8Encoding($false, $true)
$script:exe = Join-Path $PSHOME 'powershell.exe'

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if (-not [object]::Equals($Actual, $Expected)) {
        throw ($Message + ': expected [' + $Expected + '] actual [' + $Actual + ']')
    }
}
function Is-Absolute([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match '^(\\\\[?.]\\)' -or $Value -match '[\x00-\x1f]') { return $false }
    if ($Value -match '^[a-zA-Z]:[\\/]') { return $Value.Substring(2).IndexOf(':') -lt 0 }
    return ($Value -match '^\\\\[^\\/:]+[\\/][^\\/:]+(?:[\\/]|$)' -and $Value.IndexOf(':') -lt 0)
}
function Full([string]$Value) { return [IO.Path]::GetFullPath($Value) }
function Inside([string]$Child, [string]$Parent) {
    $prefix = $Parent.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    return $Child.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}
function No-Reparse([string]$Value) {
    $node = New-Object IO.DirectoryInfo($Value)
    while ($null -ne $node) {
        Assert-True (($node.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse point in fixture path'
        $node = $node.Parent
    }
}
function Budget {
    if ($script:clock.Elapsed.TotalSeconds -ge 120) { throw 'test budget exceeded (120 seconds)' }
}
function RemainingMs([int]$Ceiling = 30000) {
    Budget
    return [int][Math]::Max(1, [Math]::Min($Ceiling, 120000 - $script:clock.ElapsedMilliseconds))
}
function Quote-Arg([string]$Value) {
    # CommandLineToArgvW/CRT quoting, including empty strings and trailing slashes.
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) { $slashes++; continue }
        if ($character -eq [char]34) {
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
function Stop-Owned($Child) {
    if ($null -eq $Child -or $Child.Process.HasExited) { return }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $info.Arguments = '/PID ' + $Child.Process.Id + ' /T /F'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $killer = New-Object Diagnostics.Process
    $killer.StartInfo = $info
    try {
        if ($killer.Start()) {
            $outTask = $killer.StandardOutput.ReadToEndAsync()
            $errTask = $killer.StandardError.ReadToEndAsync()
            if (-not $killer.WaitForExit(3000)) { $killer.Kill() }
            [void]$killer.WaitForExit(1000)
            [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask, $errTask), 1000)
        }
    } finally { $killer.Dispose() }
    if (-not $Child.Process.WaitForExit(2000)) {
        $Child.Process.Kill()
        Assert-True ($Child.Process.WaitForExit(1000)) 'owned child did not terminate'
    }
}
function Start-Child([string]$ScriptFile, [string[]]$Arguments) {
    Budget
    Assert-True ([IO.File]::Exists($ScriptFile)) ('test startup: script missing: ' + $ScriptFile)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:exe
    $all = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptFile) + $Arguments
    $info.Arguments = (($all | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $script:utf8
    $info.StandardErrorEncoding = $script:utf8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try { Assert-True ($process.Start()) 'test startup: Process.Start returned false' }
    catch { $process.Dispose(); throw ('test startup: ' + $_.Exception.Message) }
    $child = [pscustomobject]@{
        Process = $process
        Out = $process.StandardOutput.ReadToEndAsync()
        Err = $process.StandardError.ReadToEndAsync()
        Watch = [Diagnostics.Stopwatch]::StartNew()
    }
    [void]$script:children.Add($child)
    return $child
}
function Finish-Child($Child) {
    try {
        Assert-True ($Child.Watch.ElapsedMilliseconds -lt 30000) 'child timeout (30 seconds)'
        $allowance = [int][Math]::Max(1, 30000 - $Child.Watch.ElapsedMilliseconds)
        if (-not $Child.Process.WaitForExit((RemainingMs $allowance))) {
            throw 'child timeout (30 seconds or test budget)'
        }
        Assert-True ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($Child.Out, $Child.Err), (RemainingMs 2000))) 'stdout/stderr drain timeout'
        return [pscustomobject]@{ Code = $Child.Process.ExitCode; Stdout = $Child.Out.Result; Stderr = $Child.Err.Result }
    } catch {
        $reason = $_.Exception.Message
        $beforeStop = 'running'
        if ($Child.Process.HasExited) { $beforeStop = 'exited code=' + $Child.Process.ExitCode }
        # Preserve natural failures before disposing the process. A hard timeout
        # must still stop our tree, with the forced termination clearly labelled.
        if (-not $Child.Process.HasExited) { Stop-Owned $Child }
        $drained = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($Child.Out, $Child.Err), 2000)
        $code = '<running>'
        if ($Child.Process.HasExited) { $code = [string]$Child.Process.ExitCode }
        $stdout = '<stdout drain incomplete>'; $stderr = '<stderr drain incomplete>'
        if ($Child.Out.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) { $stdout = $Child.Out.Result }
        if ($Child.Err.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) { $stderr = $Child.Err.Result }
        throw ($reason + '; before_cleanup=' + $beforeStop + '; code=' + $code + '; streams_drained=' + $drained + '; stdout=' + $stdout + '; stderr=' + $stderr)
    } finally {
        Stop-Owned $Child
        if ($Child.Out.IsCompleted -and $Child.Err.IsCompleted) {
            [void]$script:children.Remove($Child)
            $Child.Process.Dispose()
        }
    }
}
function Invoke-Lock([string[]]$Arguments) {
    return Finish-Child (Start-Child $script:lockScript $Arguments)
}
function Protocol($Result, [string]$Status, [int]$Code) {
    Assert-Equal $Result.Code $Code ('exit code; stdout=' + $Result.Stdout + '; stderr=' + $Result.Stderr)
    Assert-Equal $Result.Stderr '' 'unexpected stderr / startup failure'
    $lines = @($Result.Stdout -split '\r?\n')
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    Assert-True ($lines.Count -gt 0) 'missing status line'
    Assert-Equal $lines[0] ('status=' + $Status) 'first protocol line'
    $fields = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($line in $lines) {
        Assert-True ($line -cmatch '^([a-z0-9_]+)=([^\r\n]*)$') ('invalid protocol line: ' + $line)
        $key = $Matches[1]; $value = $Matches[2]
        Assert-True (-not $fields.ContainsKey($key)) ('duplicate protocol key: ' + $key)
        $fields.Add($key, $value)
    }
    if ($Status -eq 'usage' -or $Status -eq 'error') {
        Assert-True ($fields.ContainsKey('message') -and $fields['message'].Length -gt 0) 'missing message'
    }
    return ,$fields
}
function Case([string]$Name, [scriptblock]$Body) {
    try { Budget; & $Body; $script:pass++; [Console]::WriteLine('PASS ' + $Name) }
    catch {
        $script:fail++
        [Console]::WriteLine('FAIL ' + $Name + ': ' + ($_.Exception.Message -replace '\r\n|\r|\n', ' '))
    }
}
function Write-Text([string]$Path, [string]$Value) { [IO.File]::WriteAllText($Path, $Value, $script:utf8) }
function Bytes([string]$Path) { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }
function Hash-File([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Path-New([string]$Leaf) { return Join-Path $script:ownedRoot ($Leaf + '-' + [Guid]::NewGuid().ToString('N')) }
function Seed([string]$Id = 'Owner-AbC12345', [string]$Started = '2020-01-02T03:04:05+00:00', [string]$Task = '中文 task [x] ''quote''') {
    $path = Path-New '标记 [一] ''锁'''
    Write-Text $path ("id=$Id`nstarted=$Started`ntask=$Task`n")
    return $path
}
function No-Temps {
    $leftovers = @([IO.Directory]::GetFiles($script:ownedRoot, '*.tmp', [IO.SearchOption]::AllDirectories))
    Assert-Equal $leftovers.Count 0 'temporary file leaked'
}
function Unchanged([string]$Path, [string]$Before) { Assert-Equal (Bytes $Path) $Before 'original bytes changed' }
function Other-Fields($Fields, [string]$Id, [string]$Started, [string]$Task) {
    Assert-Equal $Fields['holder_id8'] $Id.Substring(0, [Math]::Min(8, $Id.Length)) 'holder id prefix'
    Assert-Equal $Fields['started'] $Started 'started field'
    Assert-Equal $Fields['task'] $Task 'task field'
    Assert-True ($Fields.ContainsKey('age_minutes')) 'missing age_minutes'
}

try {
    # Manual validation: never prompt and never default to the system temp folder.
    if (-not (Is-Absolute $TempRoot) -or -not [IO.Directory]::Exists($TempRoot)) {
        [Console]::WriteLine('status=usage'); [Console]::WriteLine('message=TempRoot must be an existing absolute directory'); exit 2
    }
    $TempRoot = Full $TempRoot
    if ([IO.Path]::GetPathRoot($TempRoot).Equals([IO.Path]::GetPathRoot($env:SystemRoot), [StringComparison]::OrdinalIgnoreCase)) {
        [Console]::WriteLine('status=usage'); [Console]::WriteLine('message=TempRoot must not be on the system drive'); exit 2
    }
    if ($PSBoundParameters.ContainsKey('ControlRoot')) {
        if (-not (Is-Absolute $ControlRoot) -or -not [IO.Directory]::Exists($ControlRoot)) {
            [Console]::WriteLine('status=usage'); [Console]::WriteLine('message=ControlRoot must be an existing absolute directory inside TempRoot'); exit 2
        }
        $ControlRoot = Full $ControlRoot
        if (-not (Inside $ControlRoot $TempRoot)) {
            [Console]::WriteLine('status=usage'); [Console]::WriteLine('message=ControlRoot must be inside TempRoot'); exit 2
        }
        try { No-Reparse $ControlRoot } catch {
            [Console]::WriteLine('status=usage'); [Console]::WriteLine('message=ControlRoot must not contain reparse points'); exit 2
        }
    } else {
        $ControlRoot = Full (Join-Path $PSScriptRoot '..\..\..\scripts\control')
    }
    $script:lockScript = Join-Path $ControlRoot 'lock.ps1'
    $script:ownedRoot = Join-Path $TempRoot ('lock 中文 空格 ''单引号'' [方括号]-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:ownedRoot)
    if (-not [IO.File]::Exists($script:lockScript)) {
        Case 'startup-script-present' { throw ('test startup: missing ' + $script:lockScript) }
    } else {
        Case 'acquire-default-guid-and-exact-bytes' {
            $path = Path-New 'default'
            $task = "中文 '引号' [x] = value `"double`"`r`nnext`rlast`nend"
            $fields = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Task', $task)) 'acquired' 0
            $id = [Guid]::Empty
            Assert-True ([Guid]::TryParse($fields['id'], [ref]$id)) 'default id is not a GUID'
            Assert-True ($id -ne [Guid]::Empty) 'default GUID is empty'
            $raw = [IO.File]::ReadAllBytes($path)
            Assert-True (-not ($raw.Length -ge 3 -and $raw[0] -eq 239 -and $raw[1] -eq 187 -and $raw[2] -eq 191)) 'lock has BOM'
            $text = $script:utf8.GetString($raw)
            Assert-True ($text.IndexOf("`r") -lt 0) 'lock has CR'
            $parts = $text.Split([char]10)
            Assert-Equal $parts.Count 4 'exactly three lines and terminal LF'
            Assert-Equal $parts[0] ('id=' + $fields['id']) 'id bytes'
            Assert-True ($parts[1] -cmatch '^started=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$') 'started format'
            $parsed = [DateTimeOffset]::MinValue
            Assert-True ([DateTimeOffset]::TryParseExact($parts[1].Substring(8), 'yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) 'started cannot parse'
            Assert-True ([Math]::Abs(([DateTimeOffset]::Now - $parsed).TotalSeconds) -lt 30) 'started is not current'
            Assert-Equal $parts[2] ('task=' + ($task -replace '\r\n|\r|\n', ' ')) 'task newline sanitization'
            Assert-Equal $parts[3] '' 'terminal LF'
            $before = Bytes $path
            $other = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Task', 'again')) 'held-by-other' 1
            Assert-Equal $other['holder_id8'] $fields['id'].Substring(0, 8) 'omitted Id must not reclaim old GUID'
            Unchanged $path $before
            $secondPath = Path-New 'second-default'
            $second = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $secondPath, '-Task', 'new')) 'acquired' 0
            Assert-True ($second['id'] -cne $fields['id']) 'default GUID reused'
            No-Temps
        }
        Case 'explicit-acquire-self-preserves-bytes' {
            $path = Path-New 'explicit'
            $fields = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Task', 'task', '-Id', 'CaseSensitive-ID')) 'acquired' 0
            Assert-Equal $fields['id'] 'CaseSensitive-ID' 'explicit id'
            Assert-True ([IO.File]::ReadAllText($path, $script:utf8).StartsWith("id=CaseSensitive-ID`n")) 'file id'
            $before = Bytes $path
            $self = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Task', 'must not replace', '-Id', 'CaseSensitive-ID')) 'held-by-self' 0
            Assert-Equal $self['id'] 'CaseSensitive-ID' 'self id'
            Unchanged $path $before; No-Temps
        }
        foreach ($action in @('acquire', 'check', 'release', 'guard')) {
            $currentAction = $action
            Case ($action + '-other-case-sensitive-and-preserves') {
                $path = Seed 'AbCdEfGh-OWNER'
                $before = Bytes $path
                $parameters = @('-Action', $currentAction, '-LockPath', $path, '-Id', 'abcdefgh-owner')
                if ($currentAction -eq 'acquire') { $parameters += @('-Task', 'different') }
                if ($currentAction -eq 'guard') { $parameters += @('-File', (Path-New 'missing'), '-ExpectHash', 'none') }
                $fields = Protocol (Invoke-Lock $parameters) 'held-by-other' 1
                Other-Fields $fields 'AbCdEfGh-OWNER' '2020-01-02T03:04:05+00:00' "中文 task [x] 'quote'"
                $expectedAge = [Math]::Floor(([DateTimeOffset]::Now - [DateTimeOffset]::Parse('2020-01-02T03:04:05+00:00')).TotalMinutes)
                Assert-True ([Math]::Abs([long]$fields['age_minutes'] - $expectedAge) -le 1) 'age_minutes differs from independent computation'
                Unchanged $path $before; No-Temps
            }
        }
        foreach ($action in @('check', 'release', 'guard')) {
            $currentAction = $action
            Case ($action + '-missing') {
                $path = Path-New 'missing'
                $parameters = @('-Action', $currentAction, '-LockPath', $path, '-Id', 'owner')
                if ($currentAction -eq 'guard') { $parameters += @('-File', (Path-New 'file'), '-ExpectHash', 'none') }
                $null = Protocol (Invoke-Lock $parameters) 'lock-missing' 1
                Assert-True (-not [IO.File]::Exists($path)) 'missing lock created'
            }
        }
        foreach ($kind in @('empty', 'missing-id', 'empty-id', 'duplicate-id', 'invalid-utf8')) {
            $currentKind = $kind
            Case ('all-actions-lock-empty-' + $kind) {
                $path = Path-New $currentKind
                switch ($currentKind) {
                    'empty' { Write-Text $path '' }
                    'missing-id' { Write-Text $path "started=x`ntask=x`n" }
                    'empty-id' { Write-Text $path "id=`nstarted=x`ntask=x`n" }
                    'duplicate-id' { Write-Text $path "id=owner`nid=owner`nstarted=x`ntask=x`n" }
                    'invalid-utf8' { [IO.File]::WriteAllBytes($path, [byte[]]@(255, 254, 128)) }
                }
                $before = Bytes $path
                foreach ($operation in @('acquire', 'check', 'release', 'guard')) {
                    $parameters = @('-Action', $operation, '-LockPath', $path, '-Id', 'owner')
                    if ($operation -eq 'acquire') { $parameters += @('-Task', 'new') }
                    if ($operation -eq 'guard') { $parameters += @('-File', (Path-New 'guardfile'), '-ExpectHash', 'none') }
                    $null = Protocol (Invoke-Lock $parameters) 'lock-empty' 1
                    Unchanged $path $before
                }
                No-Temps
            }
        }
        Case 'unreadable-lock-all-actions' {
            $path = Seed 'owner'; $before = Bytes $path
            $handle = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                foreach ($operation in @('acquire', 'check', 'release', 'guard')) {
                    $parameters = @('-Action', $operation, '-LockPath', $path, '-Id', 'owner')
                    if ($operation -eq 'acquire') { $parameters += @('-Task', 'new') }
                    if ($operation -eq 'guard') { $parameters += @('-File', (Path-New 'guardfile'), '-ExpectHash', 'none') }
                    $null = Protocol (Invoke-Lock $parameters) 'lock-empty' 1
                }
            } finally { $handle.Dispose() }
            Unchanged $path $before; No-Temps
        }
        Case 'missing-optional-marker-fields-crlf-bom' {
            $path = Path-New 'partial-marker'
            [IO.File]::WriteAllText($path, "id=short`r`n", (New-Object Text.UTF8Encoding($true)))
            $before = Bytes $path
            $fields = Protocol (Invoke-Lock @('-Action', 'check', '-LockPath', $path, '-Id', 'other')) 'held-by-other' 1
            Other-Fields $fields 'short' '' ''
            Assert-Equal $fields['age_minutes'] '' 'missing started age'
            Unchanged $path $before
        }
        Case 'invalid-started' {
            $path = Seed 'owner' 'not-a-date'; $before = Bytes $path
            $fields = Protocol (Invoke-Lock @('-Action', 'check', '-LockPath', $path, '-Id', 'other')) 'held-by-other' 1
            Other-Fields $fields 'owner' 'not-a-date' "中文 task [x] 'quote'"
            Assert-Equal $fields['age_minutes'] '' 'invalid date age'
            Unchanged $path $before
        }
        Case 'future-started-negative-age' {
            $started = [DateTimeOffset]::Now.AddMinutes(90).ToString('yyyy-MM-ddTHH:mm:sszzz')
            $path = Seed 'owner' $started
            $fields = Protocol (Invoke-Lock @('-Action', 'check', '-LockPath', $path, '-Id', 'other')) 'held-by-other' 1
            Assert-Equal $fields['started'] $started 'future started'
            Assert-True ([long]$fields['age_minutes'] -le -88 -and [long]$fields['age_minutes'] -ge -91) 'future age must be negative'
        }
        Case 'check-self-release-self' {
            $path = Seed 'owner'; $before = Bytes $path
            $null = Protocol (Invoke-Lock @('-Action', 'check', '-LockPath', $path, '-Id', 'owner')) 'held-by-self' 0
            Unchanged $path $before
            $null = Protocol (Invoke-Lock @('-Action', 'release', '-LockPath', $path, '-Id', 'owner')) 'released' 0
            Assert-True (-not [IO.File]::Exists($path)) 'released lock still exists'; No-Temps
        }
        Case 'release-delete-io-failure' {
            $path = Seed 'owner'; $before = Bytes $path
            $handle = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try { $null = Protocol (Invoke-Lock @('-Action', 'release', '-LockPath', $path, '-Id', 'owner')) 'error' 3 }
            finally { $handle.Dispose() }
            Unchanged $path $before; No-Temps
        }
        Case 'hash-independent-and-readonly' {
            $path = Path-New 'hash'; [IO.File]::WriteAllBytes($path, [byte[]]@(0, 255, 128, 13, 10, 42))
            $before = Bytes $path
            $fields = Protocol (Invoke-Lock @('-Action', 'hash', '-File', $path)) 'ok' 0
            Assert-True ($fields['hash'] -cmatch '^[0-9a-f]{64}$') 'hash must be lower-case SHA256'
            Assert-Equal $fields['hash'] (Hash-File $path) 'independent SHA256'
            Unchanged $path $before
        }
        Case 'hash-missing' {
            $path = Path-New 'missing'
            $null = Protocol (Invoke-Lock @('-Action', 'hash', '-File', $path)) 'file-missing' 1
            Assert-True (-not [IO.File]::Exists($path)) 'hash created missing file'
        }
        Case 'hash-io-not-missing' {
            $path = Path-New 'hash-io'; Write-Text $path 'content'; $before = Bytes $path
            $handle = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { $null = Protocol (Invoke-Lock @('-Action', 'hash', '-File', $path)) 'error' 3 }
            finally { $handle.Dispose() }
            Unchanged $path $before
        }
        foreach ($mode in @('same', 'uppercase', 'different', 'missing-hash', 'none-missing', 'none-present', 'NONE-missing')) {
            $currentMode = $mode
            Case ('guard-' + $mode) {
                $lock = Seed 'owner'; $lockBefore = Bytes $lock
                $file = Path-New 'guard-data'; Write-Text $file '中文 = original'
                $expected = Hash-File $file; $actual = $expected
                $status = 'ok'; $code = 0
                switch ($currentMode) {
                    'uppercase' { $expected = $expected.ToUpperInvariant() }
                    'different' { Write-Text $file 'changed'; $actual = Hash-File $file; $status = 'file-changed'; $code = 1 }
                    'missing-hash' { [IO.File]::Delete($file); $actual = ''; $status = 'file-changed'; $code = 1 }
                    'none-missing' { [IO.File]::Delete($file); $expected = 'none' }
                    'NONE-missing' { [IO.File]::Delete($file); $expected = 'NONE' }
                    'none-present' { $expected = 'none'; $status = 'file-changed'; $code = 1 }
                }
                $fileBefore = $null
                if ([IO.File]::Exists($file)) { $fileBefore = Bytes $file }
                $fields = Protocol (Invoke-Lock @('-Action', 'guard', '-LockPath', $lock, '-Id', 'owner', '-File', $file, '-ExpectHash', $expected)) $status $code
                if ($status -eq 'file-changed') { Assert-Equal $fields['current_hash'] $actual 'current_hash' }
                Unchanged $lock $lockBefore
                if ($null -ne $fileBefore) { Unchanged $file $fileBefore } else { Assert-True (-not [IO.File]::Exists($file)) 'guard created file' }
                No-Temps
            }
        }
        Case 'guard-io-not-conflict' {
            $lock = Seed 'owner'; $lockBefore = Bytes $lock
            $file = Path-New 'guard-io'; Write-Text $file 'content'; $before = Bytes $file
            $handle = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { $null = Protocol (Invoke-Lock @('-Action', 'guard', '-LockPath', $lock, '-Id', 'owner', '-File', $file, '-ExpectHash', 'none')) 'error' 3 }
            finally { $handle.Dispose() }
            Unchanged $lock $lockBefore; Unchanged $file $before
        }
        Case 'acquire-permission-io-not-conflict' {
            $directory = Path-New 'deny-create'; [void][IO.Directory]::CreateDirectory($directory)
            $originalAcl = Get-Acl -LiteralPath $directory
            $acl = Get-Acl -LiteralPath $directory
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]::CreateFiles, [Security.AccessControl.AccessControlType]::Deny)
            [void]$acl.AddAccessRule($rule)
            try {
                Set-Acl -LiteralPath $directory -AclObject $acl
                $path = Join-Path $directory 'lock'
                $null = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Id', 'owner', '-Task', 'task')) 'error' 3
                Assert-True (-not [IO.File]::Exists($path)) 'failed acquire created lock'
            } finally { Set-Acl -LiteralPath $directory -AclObject $originalAcl }
            No-Temps
        }
        foreach ($empty in @($false, $true)) {
            $isEmpty = $empty
            Case ('retry-exhausted-empty=' + $empty) {
                $path = Seed 'other'; if ($isEmpty) { Write-Text $path '' }
                $before = Bytes $path
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $result = Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Id', 'owner', '-Task', 'task', '-Retry', '2', '-WaitSec', '1')
                $status = 'held-by-other'; if ($isEmpty) { $status = 'lock-empty' }
                $fields = Protocol $result $status 1
                Assert-Equal $fields['attempts'] '3' 'Retry=2 total attempts'
                Assert-True ($watch.Elapsed.TotalSeconds -ge 1.7 -and $watch.Elapsed.TotalSeconds -lt 15) 'bounded retry elapsed time'
                Unchanged $path $before; No-Temps
            }
        }
        Case 'retry-wait-boundaries-accepted' {
            $path = Path-New 'retry-boundaries'
            $fields = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Id', 'boundary-owner', '-Task', 'task', '-Retry', '10', '-WaitSec', '60')) 'acquired' 0
            Assert-Equal $fields['id'] 'boundary-owner' 'upper-bound arguments rejected'
            $before = Bytes $path
            $other = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Id', 'other', '-Task', 'task', '-Retry', '2', '-WaitSec', '0')) 'held-by-other' 1
            Assert-Equal $other['attempts'] '3' 'zero-wait retry count'
            Unchanged $path $before; No-Temps
        }

        # Helpers are generated only inside the fixture. Start-Sleep is a signal
        # seam, not a guessed delay: release waits until the first retry backoff.
        $wrapper = Join-Path $script:ownedRoot 'event runner.ps1'
        Write-Text $wrapper @'
param([string]$Target,[string]$Lock,[string]$Identity,[string]$Ready,[string]$Go,[string]$Mode)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$readyEvent=[Threading.EventWaitHandle]::OpenExisting($Ready)
$goEvent=$null
try {
    $goEvent=[Threading.EventWaitHandle]::OpenExisting($Go)
    if($Mode -eq 'retry') {
        # Bind these exact handles to a private closure module. The target ps1
        # has its own script scope, so $script: references are not safe here.
        Set-Item -LiteralPath Function:\Start-Sleep -Value ({
            param([int]$Seconds,[int]$Milliseconds)
            [void]$readyEvent.Set()
            if(-not $goEvent.WaitOne(10000)){throw 'retry release signal timeout'}
            if($PSBoundParameters.ContainsKey('Milliseconds')){Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds}
            else{Microsoft.PowerShell.Utility\Start-Sleep -Seconds $Seconds}
        }.GetNewClosure())
        & $Target -Action acquire -LockPath $Lock -Id $Identity -Task 'retry task' -Retry 2 -WaitSec 1
    } else {
        [void]$readyEvent.Set()
        if(-not $goEvent.WaitOne(10000)){throw 'start barrier timeout'}
        & $Target -Action acquire -LockPath $Lock -Id $Identity -Task 'concurrent task'
    }
    exit $LASTEXITCODE
} finally {$readyEvent.Dispose();if($null -ne $goEvent){$goEvent.Dispose()}}
'@
        Case 'retry-release-after-backoff-signal' {
            $path = Seed 'old-owner'
            $token = 'Local\lock-test-' + [Guid]::NewGuid().ToString('N')
            $ready = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, ($token + '-ready'))
            $go = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, ($token + '-go'))
            $child = $null
            try {
                $child = Start-Child $wrapper @('-Target', $script:lockScript, '-Lock', $path, '-Identity', 'new-owner', '-Ready', ($token + '-ready'), '-Go', ($token + '-go'), '-Mode', 'retry')
                if (-not $ready.WaitOne((RemainingMs 10000))) {
                    # Collect the child's real failure before final cleanup; a
                    # late/absent signal remains FAIL regardless of its result.
                    $result = Finish-Child $child
                    $child = $null
                    throw ('no first-backoff signal (Start-Sleep seam not reached); code=' + $result.Code + '; stdout=' + $result.Stdout + '; stderr=' + $result.Stderr)
                }
                $null = Protocol (Invoke-Lock @('-Action', 'release', '-LockPath', $path, '-Id', 'old-owner')) 'released' 0
                Assert-True (-not [IO.File]::Exists($path)) 'release did not remove old lock'
                [void]$go.Set()
                $fields = Protocol (Finish-Child $child) 'acquired' 0
                $child = $null
                Assert-Equal $fields['id'] 'new-owner' 'retry acquired id'
                Assert-True (-not $fields.ContainsKey('attempts')) 'success leaked failure attempts'
                Assert-True ([IO.File]::ReadAllText($path, $script:utf8).StartsWith("id=new-owner`n")) 'retry did not own real file'
                No-Temps
            } finally {
                [void]$go.Set()
                if ($null -ne $child -and $script:children.Contains($child)) { Stop-Owned $child }
                $ready.Dispose(); $go.Dispose()
            }
        }
        Case 'concurrent-exactly-one-acquired' {
            $path = Path-New 'race'
            $token = 'Local\lock-test-' + [Guid]::NewGuid().ToString('N')
            $readyA = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, ($token + '-a'))
            $readyB = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, ($token + '-b'))
            $go = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, ($token + '-go'))
            $a = $null; $b = $null
            try {
                $a = Start-Child $wrapper @('-Target', $script:lockScript, '-Lock', $path, '-Identity', 'racer-A', '-Ready', ($token + '-a'), '-Go', ($token + '-go'), '-Mode', 'race')
                $b = Start-Child $wrapper @('-Target', $script:lockScript, '-Lock', $path, '-Identity', 'racer-B', '-Ready', ($token + '-b'), '-Go', ($token + '-go'), '-Mode', 'race')
                Assert-True ($readyA.WaitOne((RemainingMs 10000))) 'racer A readiness timeout'
                Assert-True ($readyB.WaitOne((RemainingMs 10000))) 'racer B readiness timeout'
                [void]$go.Set()
                $ra = Finish-Child $a; $a = $null
                $rb = Finish-Child $b; $b = $null
                $winner = $null; $loser = $null; $winnerId = $null
                if ($ra.Stdout.StartsWith("status=acquired`n") -or $ra.Stdout.StartsWith("status=acquired`r`n")) {
                    $winner = $ra; $loser = $rb; $winnerId = 'racer-A'
                } else { $winner = $rb; $loser = $ra; $winnerId = 'racer-B' }
                $won = Protocol $winner 'acquired' 0
                $lost = Protocol $loser 'held-by-other' 1
                Assert-Equal $won['id'] $winnerId 'winner identity'
                Assert-Equal $lost['holder_id8'] $winnerId 'loser reports actual winner'
                Assert-True ([IO.File]::ReadAllText($path, $script:utf8).StartsWith(('id=' + $winnerId + "`n"))) 'real lock differs from winning result'
                No-Temps
            } finally {
                [void]$go.Set()
                foreach ($child in @($a, $b)) { if ($null -ne $child -and $script:children.Contains($child)) { Stop-Owned $child } }
                $readyA.Dispose(); $readyB.Dispose(); $go.Dispose()
            }
        }
        $missingCases = @(
            @{ Name = 'action'; Values = @() },
            @{ Name = 'unknown-action'; Values = @('-Action', 'unknown') },
            @{ Name = 'acquire-lock'; Values = @('-Action', 'acquire', '-Task', 't') },
            @{ Name = 'acquire-task'; Values = @('-Action', 'acquire', '-LockPath', 'LOCK') },
            @{ Name = 'check-lock'; Values = @('-Action', 'check', '-Id', 'owner') },
            @{ Name = 'check-id'; Values = @('-Action', 'check', '-LockPath', 'LOCK') },
            @{ Name = 'release-lock'; Values = @('-Action', 'release', '-Id', 'owner') },
            @{ Name = 'release-id'; Values = @('-Action', 'release', '-LockPath', 'LOCK') },
            @{ Name = 'hash-file'; Values = @('-Action', 'hash') },
            @{ Name = 'guard-lock'; Values = @('-Action', 'guard', '-Id', 'owner', '-File', 'FILE', '-ExpectHash', 'none') },
            @{ Name = 'guard-id'; Values = @('-Action', 'guard', '-LockPath', 'LOCK', '-File', 'FILE', '-ExpectHash', 'none') },
            @{ Name = 'guard-file'; Values = @('-Action', 'guard', '-LockPath', 'LOCK', '-Id', 'owner', '-ExpectHash', 'none') },
            @{ Name = 'guard-expect'; Values = @('-Action', 'guard', '-LockPath', 'LOCK', '-Id', 'owner', '-File', 'FILE') }
        )
        foreach ($entry in $missingCases) {
            $currentEntry = $entry
            Case ('usage-missing-' + $entry.Name) {
                $lock = Seed 'owner'; $before = Bytes $lock
                $file = Path-New 'file'; Write-Text $file 'unchanged'; $fileBefore = Bytes $file
                $parameters = @($currentEntry.Values | ForEach-Object { if ($_ -ceq 'LOCK') { $lock } elseif ($_ -ceq 'FILE') { $file } else { $_ } })
                $null = Protocol (Invoke-Lock $parameters) 'usage' 2
                Unchanged $lock $before; Unchanged $file $fileBefore; No-Temps
            }
        }
        foreach ($bad in @(@('Retry', '-1'), @('Retry', '11'), @('WaitSec', '-1'), @('WaitSec', '61'))) {
            $currentBad = $bad
            Case ('usage-range-' + $bad[0] + '-' + $bad[1]) {
                $path = Path-New 'invalid-range'
                $null = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Id', 'owner', '-Task', 't', ('-' + $currentBad[0]), $currentBad[1])) 'usage' 2
                Assert-True (-not [IO.File]::Exists($path)) 'invalid range wrote lock'; No-Temps
            }
        }
        $nonintegerCases = @(
            @{ Parameter = 'Retry'; Label = 'abc'; Value = 'abc' },
            @{ Parameter = 'Retry'; Label = 'fraction'; Value = '1.5' },
            @{ Parameter = 'Retry'; Label = 'overflow'; Value = '2147483648' },
            @{ Parameter = 'WaitSec'; Label = 'abc'; Value = 'abc' },
            @{ Parameter = 'WaitSec'; Label = 'fraction'; Value = '1.5' },
            @{ Parameter = 'WaitSec'; Label = 'overflow'; Value = '2147483648' }
        )
        foreach ($noninteger in $nonintegerCases) {
            $currentNoninteger = $noninteger
            Case ('usage-noninteger-' + $noninteger.Parameter + '-' + $noninteger.Label) {
                $retryValue = '0'; $waitValue = '0'
                if ($currentNoninteger.Parameter -eq 'Retry') { $retryValue = $currentNoninteger.Value }
                else { $waitValue = $currentNoninteger.Value }
                $missing = Path-New 'noninteger-missing'
                $existing = Seed 'owner'; $before = Bytes $existing
                foreach ($path in @($missing, $existing)) {
                    $result = Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Id', 'owner', '-Task', 'must not write', '-Retry', $retryValue, '-WaitSec', $waitValue)
                    Assert-True (-not [IO.File]::Exists($missing)) 'noninteger argument created lock'
                    Unchanged $existing $before
                    No-Temps
                    $null = Protocol $result 'usage' 2
                }
            }
        }
        foreach ($badHash in @('', 'None ', 'no', ('a' * 63), ('a' * 65), ('g' * 64), "none`n")) {
            $currentHash = $badHash
            Case ('usage-expecthash-' + ($badHash -replace '\r|\n', '_')) {
                $path = Seed 'owner'; $before = Bytes $path
                $null = Protocol (Invoke-Lock @('-Action', 'guard', '-LockPath', $path, '-Id', 'owner', '-File', (Path-New 'file'), '-ExpectHash', $currentHash)) 'usage' 2
                Unchanged $path $before
            }
        }
        Case 'usage-expecthash-before-lock-lookup' {
            $lock = Path-New 'missing-lock'
            $null = Protocol (Invoke-Lock @('-Action', 'guard', '-LockPath', $lock, '-Id', 'owner', '-File', (Path-New 'missing-file'), '-ExpectHash', 'invalid')) 'usage' 2
            Assert-True (-not [IO.File]::Exists($lock)) 'invalid hash created lock'
        }
        foreach ($operation in @('acquire', 'check', 'release', 'guard')) {
            $currentOperation = $operation
            foreach ($badId in @('', "owner`nnext", "owner`rnext")) {
                $currentId = $badId
                Case ('usage-id-' + $operation + '-' + ($badId -replace '\r|\n', '_')) {
                    $path = Seed 'owner'; $before = Bytes $path
                    $parameters = @('-Action', $currentOperation, '-LockPath', $path, '-Id', $currentId)
                    if ($currentOperation -eq 'acquire') { $parameters += @('-Task', 't') }
                    if ($currentOperation -eq 'guard') { $parameters += @('-File', (Path-New 'file'), '-ExpectHash', 'none') }
                    $null = Protocol (Invoke-Lock $parameters) 'usage' 2
                    Unchanged $path $before
                }
            }
        }
        Case 'usage-empty-task' {
            $path = Path-New 'empty-task'
            $null = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Task', '')) 'usage' 2
            Assert-True (-not [IO.File]::Exists($path)) 'empty task wrote lock'
        }
        Case 'usage-parent-missing' {
            $directory = Path-New 'missing-parent'; $path = Join-Path $directory 'lock'
            $fields = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $path, '-Task', 't')) 'usage' 2
            Assert-Equal $fields['message'] 'lock directory missing' 'missing parent message'
            Assert-True (-not [IO.Directory]::Exists($directory)) 'missing parent created'
        }
        foreach ($badPath in @('relative\lock', '\root-relative', 'Z:relative', '\\?\C:\lock', '\\.\C:\lock')) {
            $currentPath = $badPath
            Case ('usage-path-' + $badPath) {
                $null = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', $currentPath, '-Task', 't')) 'usage' 2
            }
        }
        Case 'usage-ads-path' {
            $path = Path-New 'ads'
            $null = Protocol (Invoke-Lock @('-Action', 'acquire', '-LockPath', ($path + ':stream'), '-Task', 't')) 'usage' 2
            Assert-True (-not [IO.File]::Exists($path)) 'ADS validation created base file'
        }
        foreach ($operation in @('acquire', 'check', 'release', 'hash', 'guard')) {
            $currentOperation = $operation
            Case ('usage-directory-' + $operation) {
                $parameters = @('-Action', $currentOperation)
                if ($currentOperation -eq 'hash') { $parameters += @('-File', $script:ownedRoot) }
                else {
                    $parameters += @('-LockPath', $script:ownedRoot, '-Id', 'owner')
                    if ($currentOperation -eq 'acquire') { $parameters += @('-Task', 't') }
                    if ($currentOperation -eq 'guard') { $parameters += @('-File', (Path-New 'file'), '-ExpectHash', 'none') }
                }
                $null = Protocol (Invoke-Lock $parameters) 'usage' 2
                Assert-True ([IO.Directory]::Exists($script:ownedRoot)) 'directory removed'
            }
        }
        Case 'usage-guard-file-directory-before-lock-lookup' {
            $null = Protocol (Invoke-Lock @('-Action', 'guard', '-LockPath', (Path-New 'missing'), '-Id', 'owner', '-File', $script:ownedRoot, '-ExpectHash', 'none')) 'usage' 2
        }
        Case 'final-no-temporary-files' { No-Temps }
    }
} catch {
    $script:fail++
    [Console]::WriteLine('FAIL harness: ' + ($_.Exception.Message -replace '\r\n|\r|\n', ' '))
} finally {
    foreach ($child in @($script:children.ToArray())) {
        try {
            Stop-Owned $child
            Assert-True ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($child.Out, $child.Err), 2000)) 'cleanup stream drain timeout'
            $child.Process.Dispose()
        } catch { $script:fail++; [Console]::WriteLine('FAIL process-cleanup: ' + ($_.Exception.Message -replace '\r\n|\r|\n', ' ')) }
    }
    if ($null -ne $script:ownedRoot -and [IO.Directory]::Exists($script:ownedRoot)) {
        try {
            [IO.Directory]::Delete($script:ownedRoot, $true)
            Assert-True (-not [IO.Directory]::Exists($script:ownedRoot)) 'owned directory still exists'
            $script:pass++; [Console]::WriteLine('PASS owned-fixture-cleanup')
        } catch { $script:fail++; [Console]::WriteLine('FAIL fixture-cleanup: ' + ($_.Exception.Message -replace '\r\n|\r|\n', ' ')) }
    }
}
[Console]::WriteLine(('summary pass={0} fail={1}' -f $script:pass, $script:fail))
if ($script:fail -gt 0) { exit 1 }
exit 0
