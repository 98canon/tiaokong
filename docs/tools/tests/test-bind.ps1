param(
    [string]$TempRoot,
    [string]$ControlRoot
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

# Independent contract tests. Never import or inspect the implementation.
$script:Passed = 0
$script:Failed = 0
$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:OwnedRoot = $null
$script:Children = New-Object System.Collections.ArrayList
$script:Utf8 = New-Object Text.UTF8Encoding($false, $true)

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Message (expected=<$Expected>; actual=<$Actual>)"
    }
}
function Assert-Bytes([string]$Path, [byte[]]$Expected) {
    $actual = [IO.File]::ReadAllBytes($Path)
    Assert-Equal ([Convert]::ToBase64String($actual)) ([Convert]::ToBase64String($Expected)) "Bytes changed: $Path"
}
function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}
function New-Directory([string]$Path) {
    [void][IO.Directory]::CreateDirectory($Path)
    return [IO.Path]::GetFullPath($Path)
}
function Test-Absolute([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '^[\\/]{2}[?.][\\/]') { return $false }
    if ($Path -match '^[a-zA-Z]:[\\/]') { return $Path.Substring(2).IndexOf(':') -lt 0 }
    return ($Path -match '^[\\/]{2}[^\\/:]+[\\/][^\\/:]+(?:[\\/][^:]*)?$')
}
function Test-Inside([string]$Path, [string]$Parent) {
    $a = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $b = [IO.Path]::GetFullPath($Parent).TrimEnd([char[]]'\/')
    return $a.Equals($b, [StringComparison]::OrdinalIgnoreCase) -or $a.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Assert-NoReparse([string]$Path) {
    $item = New-Object IO.DirectoryInfo([IO.Path]::GetFullPath($Path))
    while ($null -ne $item) {
        Assert-True (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'ControlRoot has a reparse-point ancestor'
        $item = $item.Parent
    }
}
function Quote-WindowsArg([string]$Value) {
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]92) { $slashes++; continue }
        if ($ch -eq [char]34) {
            [void]$builder.Append([char]92, (2 * $slashes + 1))
            [void]$builder.Append($ch)
        } else {
            [void]$builder.Append([char]92, $slashes)
            [void]$builder.Append($ch)
        }
        $slashes = 0
    }
    [void]$builder.Append([char]92, (2 * $slashes))
    [void]$builder.Append('"')
    return $builder.ToString()
}
function Stop-OwnedProcess([Diagnostics.Process]$Process) {
    if ($Process.HasExited) { return }
    # taskkill targets only a PID obtained from our successful Process.Start.
    $killInfo = New-Object Diagnostics.ProcessStartInfo
    $killInfo.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $killInfo.Arguments = '/PID ' + $Process.Id + ' /T /F'
    $killInfo.UseShellExecute = $false
    $killInfo.CreateNoWindow = $true
    $killInfo.RedirectStandardOutput = $true
    $killInfo.RedirectStandardError = $true
    $killer = New-Object Diagnostics.Process
    $killer.StartInfo = $killInfo
    try {
        if (-not $killer.Start()) { throw 'Unable to start owned-tree cleanup' }
        $outTask = $killer.StandardOutput.ReadToEndAsync()
        $errTask = $killer.StandardError.ReadToEndAsync()
        if (-not $killer.WaitForExit(2000)) { $killer.Kill() }
        [void]$killer.WaitForExit(1000)
        [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask, $errTask), 1000)
        if (-not $Process.WaitForExit(2000)) {
            $Process.Kill()
            if (-not $Process.WaitForExit(1000)) { throw 'Owned process did not terminate' }
        }
    } finally { $killer.Dispose() }
}
function Invoke-Bind([string[]]$Arguments) {
    $remaining = 120000 - $script:Clock.ElapsedMilliseconds
    if ($remaining -le 0) { throw 'Internal 120-second budget exhausted' }
    if (-not [IO.File]::Exists($script:BindScript)) { throw "TEST START FAILURE: bind.ps1 missing: $script:BindScript" }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $values = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:BindScript) + $Arguments
    $info.Arguments = (($values | ForEach-Object { Quote-WindowsArg $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $script:Utf8
    $info.StandardErrorEncoding = $script:Utf8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'TEST START FAILURE: Process.Start returned false' }
        [void]$script:Children.Add($process)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $limit = [int][Math]::Min(30000, $remaining)
        if (-not $process.WaitForExit($limit)) {
            Stop-OwnedProcess $process
            [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 2000)
            throw "TIMEOUT after $limit ms; own process tree terminated"
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 2000)) {
            throw 'TIMEOUT draining stdout/stderr'
        }
        return [pscustomobject]@{ Code = $process.ExitCode; Out = $stdoutTask.Result; Err = $stderrTask.Result }
    } finally {
        try { if ($null -ne $process -and $script:Children.Contains($process) -and -not $process.HasExited) { Stop-OwnedProcess $process } }
        finally {
            [void]$script:Children.Remove($process)
            $process.Dispose()
        }
    }
}
function Assert-Protocol($Result, [string]$Status, [int]$Code) {
    Assert-Equal $Result.Code $Code 'Exit code'
    Assert-Equal $Result.Err '' 'Unexpected stderr'
    Assert-True (-not $Result.Out.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)) 'stdout BOM is forbidden'
    $text = $Result.Out.Replace("`r`n", "`n")
    Assert-True (-not $text.Contains("`r")) 'stdout contains bare CR'
    $lines = @($text.TrimEnd([char]10).Split([char]10))
    Assert-Equal $lines[0] "status=$Status" 'First protocol line'
    $fields = @{}
    foreach ($line in $lines) {
        Assert-True ($line -cmatch '^([a-z0-9_]+)=(.*)$') "Malformed protocol line: $line"
        $key = $Matches[1]
        Assert-True (-not $fields.ContainsKey($key)) "Duplicate protocol key: $key"
        $fields[$key] = $Matches[2]
    }
    return [pscustomobject]@{ Lines = $lines; Fields = $fields }
}
function Assert-Lines($Protocol, [string[]]$Expected) {
    Assert-Equal ($Protocol.Lines -join "`n") ($Expected -join "`n") 'Protocol field order/content'
}
function Assert-Failure($Result, [string]$Status, [int]$Code) {
    $protocol = Assert-Protocol $Result $Status $Code
    Assert-Equal $protocol.Lines.Count 2 'Failure must not leak partial success fields'
    Assert-True ($protocol.Fields.ContainsKey('message') -and -not [string]::IsNullOrWhiteSpace($protocol.Fields.message)) 'Missing failure message'
    if ($Status -eq 'usage') { Assert-True ($protocol.Fields.message -cmatch '^[\x20-\x7e]+$') 'usage message must be English single-line text' }
}
function Identity([string]$Work, [string]$Config) {
    # Deliberately computed independently from source: preserve lexical dot segments.
    $normalized = $Work.TrimEnd([char[]]'\/').Replace('\', '/').ToLowerInvariant()
    $hashObject = [Security.Cryptography.SHA256]::Create()
    try { $digest = $hashObject.ComputeHash($script:Utf8.GetBytes($normalized)) }
    finally { $hashObject.Dispose() }
    $hash = ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    $leaf = $normalized.Substring($normalized.LastIndexOf('/') + 1)
    $slug = [regex]::Replace($leaf, '[^a-z0-9]+', '-').Trim([char]45)
    if ($slug.Length -gt 24) { $slug = $slug.Substring(0, 24).TrimEnd([char]45) }
    if ($slug.Length -eq 0) { $slug = 'p' }
    $id = $slug + '-' + $hash.Substring(0, 6)
    return [pscustomobject]@{
        Normalized = $normalized; Hash = $hash; Id = $id
        Registry = [IO.Path]::GetFullPath((Join-Path $Config ('tiaokong-registry\' + $hash + '.md')))
        Project = [IO.Path]::GetFullPath((Join-Path $Config ('tiaokong-projects\' + $id)))
    }
}
function New-Fixture([string]$Leaf = "项目 空格' [方括号]") {
    $root = New-Directory (Join-Path $script:OwnedRoot ([Guid]::NewGuid().ToString('N')))
    $work = New-Directory (Join-Path $root $Leaf)
    $config = New-Directory (Join-Path $root "配置 空格' [配置]")
    $skill = New-Directory (Join-Path $root "安装 空格' [skill]")
    return [pscustomobject]@{
        Root = $root; Work = $work; Config = $config; Skill = $skill
        Profile = Join-Path $root "档案 空格' [正文].md"
        Identity = Identity $work $config
    }
}
function Call-Bind($Fixture, [string]$Action, [string[]]$Extra = @()) {
    return Invoke-Bind (@('-Action', $Action, '-WorkDir', $Fixture.Work, '-ConfigRoot', $Fixture.Config, '-SkillDir', $Fixture.Skill) + $Extra)
}
function Set-Registry($Fixture, [string]$Text) {
    [void](New-Directory ([IO.Path]::GetDirectoryName($Fixture.Identity.Registry)))
    Write-Text $Fixture.Identity.Registry $Text
}
function Valid-Registry($Fixture, [string]$Profile = '') {
    if ($Profile -eq '') { $Profile = $Fixture.Profile }
    Set-Registry $Fixture ($Fixture.Identity.Normalized + "`n" + $Fixture.Identity.Id + "`n" + $Profile + "`n")
}
function Assert-Info($Fixture, $Result, [string]$Status, [int]$Code, [bool]$Registered = $false, [string]$RegisteredId = '', [string]$Profile = '', [string[]]$Extra = @()) {
    $protocol = Assert-Protocol $Result $Status $Code
    $id = $Fixture.Identity
    $expected = @("status=$Status", "normalized=$($id.Normalized)", "registry_name=$($id.Hash)", "project_id=$($id.Id)", "registry_file=$($id.Registry)", "project_dir=$($id.Project)")
    if ($Registered) { $expected += @("registry_project_id=$RegisteredId", "profile_path=$Profile") }
    Assert-Lines $protocol ($expected + $Extra)
}
function Assert-Location($Result, [string]$Status, [string]$FullPath, [string]$Reason = '') {
    $code = 0
    if ($Status -eq 'rejected') { $code = 1 }
    $protocol = Assert-Protocol $Result $Status $code
    $expected = @("status=$Status", "full_path=$FullPath")
    if ($Status -eq 'rejected') { $expected += "reason=$Reason" }
    Assert-Lines $protocol $expected
}
function Assert-NoTemps($Fixture) {
    $leftovers = @(Get-ChildItem -LiteralPath $Fixture.Root -Force -Recurse | Where-Object { $_.Name -like '*.tmp' })
    Assert-Equal $leftovers.Count 0 'Temporary file residue'
}
function Case([string]$Name, [scriptblock]$Body) {
    try {
        if ($script:Clock.ElapsedMilliseconds -ge 120000) { throw 'Internal 120-second budget exhausted' }
        & $Body
        $script:Passed++
        [Console]::WriteLine('PASS ' + $Name)
    } catch {
        $script:Failed++
        [Console]::WriteLine('FAIL ' + $Name + ': ' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' '))
    }
}

try {
    try {
        if (-not (Test-Absolute $TempRoot)) { throw 'TempRoot must be an absolute existing non-system directory' }
        $TempRoot = [IO.Path]::GetFullPath($TempRoot)
        if (-not [IO.Directory]::Exists($TempRoot)) { throw 'TempRoot must exist and be a directory' }
        $systemDrive = [IO.Path]::GetPathRoot($env:SystemRoot)
        if ([IO.Path]::GetPathRoot($TempRoot).Equals($systemDrive, [StringComparison]::OrdinalIgnoreCase)) { throw 'TempRoot cannot be on the system drive' }
        $formalControlRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\scripts\control'))
        if (-not [string]::IsNullOrEmpty($ControlRoot)) {
            if (-not (Test-Absolute $ControlRoot)) { throw 'ControlRoot must be absolute' }
            $ControlRoot = [IO.Path]::GetFullPath($ControlRoot)
            if (-not [IO.Directory]::Exists($ControlRoot) -or -not (Test-Inside $ControlRoot $TempRoot)) { throw 'ControlRoot must be an existing directory within TempRoot' }
            if (Test-Inside $ControlRoot $formalControlRoot) { throw 'ControlRoot must not point to the formal implementation directory' }
            Assert-NoReparse $ControlRoot
            $script:BindScript = Join-Path $ControlRoot 'bind.ps1'
        } else {
            $script:BindScript = Join-Path $formalControlRoot 'bind.ps1'
        }
    } catch {
        [Console]::WriteLine('status=usage')
        [Console]::WriteLine('message=' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' '))
        exit 2
    }
    $script:OwnedRoot = New-Directory (Join-Path $TempRoot ('test-bind-' + [Guid]::NewGuid().ToString('N')))

    Case 'startup-script-present' {
        Assert-True ([IO.File]::Exists($script:BindScript)) "TEST START FAILURE: missing bind.ps1: $script:BindScript"
    }
    foreach ($action in @('info', 'check-profile', 'write-registry')) {
        Case "$action-missing-workdir" {
            $f = New-Fixture
            Assert-Failure (Invoke-Bind @('-Action', $action, '-ConfigRoot', $f.Config, '-SkillDir', $f.Skill, '-ProfilePath', $f.Profile)) 'usage' 2
            Assert-NoTemps $f
        }
    }
    foreach ($action in @('check-profile', 'write-registry')) {
        Case "$action-missing-profile" { $f = New-Fixture; Assert-Failure (Call-Bind $f $action) 'usage' 2; Assert-NoTemps $f }
    }
    Case 'missing-and-unknown-action' {
        $f = New-Fixture
        Assert-Failure (Invoke-Bind @('-WorkDir', $f.Work, '-ConfigRoot', $f.Config)) 'usage' 2
        Assert-Failure (Call-Bind $f 'not-an-action') 'usage' 2
        Assert-NoTemps $f
    }
    foreach ($leaf in @("项目 空格' [方括号]", 'AbC___def--GhI', 'abcdefghijklmnopqrstuvwxyz0123456789', 'abcdefghijklmnopqrstuvw-XYZ_more', '纯中文')) {
        Case ('identity-' + $leaf) {
            $f = New-Fixture $leaf
            Assert-Info $f (Call-Bind $f 'info') 'not-bound' 0
            Assert-True (-not [IO.Directory]::Exists((Join-Path $f.Config 'tiaokong-registry'))) 'info created registry directory'
            Assert-True (-not [IO.Directory]::Exists($f.Identity.Project)) 'info created project directory'
            Assert-NoTemps $f
        }
    }
    Case 'identity-case-trailing-separators-and-forward-slashes' {
        $f = New-Fixture 'MixedCASE'
        foreach ($work in @($f.Work.ToUpperInvariant(), ($f.Work + '\\'), ($f.Work.Replace('\', '/') + '/'))) {
            $copy = $f.PSObject.Copy(); $copy.Work = $work; $copy.Identity = Identity $work $copy.Config
            Assert-Equal $copy.Identity.Hash $f.Identity.Hash 'Independent normalized hash'
            Assert-Info $copy (Call-Bind $copy 'info') 'not-bound' 0
        }
    }
    Case 'identity-does-not-resolve-lexical-dot-segment' {
        $f = New-Fixture 'Work'; [void](New-Directory (Join-Path $f.Work 'child'))
        $f.Work = Join-Path $f.Work 'child\..'
        $f.Identity = Identity $f.Work $f.Config
        Assert-Info $f (Call-Bind $f 'info') 'not-bound' 0
    }
    foreach ($marker in @('.tiaokong-dev', 'SKILL.md')) {
        Case ('skill-repo-' + $marker) {
            $f = New-Fixture
            $text = "---`nname: tiaokong`n---`n"
            Write-Text (Join-Path $f.Work $marker) $text
            Assert-Info $f (Call-Bind $f 'info') 'skill-repo' 1
        }
    }
    Case 'skill-repo-precedes-invalid-registry' {
        $f = New-Fixture
        $markerPath = Join-Path $f.Work '.tiaokong-dev'
        Write-Text $markerPath "development fixture`n"
        [void](New-Directory ([IO.Path]::GetDirectoryName($f.Identity.Registry)))
        $invalidBytes = [byte[]]@(0xC3, 0x28, 0xFF)
        [IO.File]::WriteAllBytes($f.Identity.Registry, $invalidBytes)
        $handle = [IO.File]::Open($f.Identity.Registry, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            Assert-Info $f (Call-Bind $f 'info') 'skill-repo' 1 $false
        } finally { $handle.Dispose() }
        Assert-Bytes $f.Identity.Registry $invalidBytes
        Assert-Bytes $markerPath ($script:Utf8.GetBytes("development fixture`n"))
        Assert-NoTemps $f
    }
    Case 'skill-name-line-must-match-exactly' {
        $f = New-Fixture
        Write-Text (Join-Path $f.Work 'SKILL.md') " name: tiaokong`nname: tiaokong-extra`n"
        Assert-Info $f (Call-Bind $f 'info') 'not-bound' 0
    }
    foreach ($rowCount in @(0, 1, 2, 4)) {
        Case "registry-line-count-$rowCount" {
            $f = New-Fixture
            $rows = @($f.Identity.Normalized, $f.Identity.Id, $f.Profile, 'extra')
            $text = ''
            if ($rowCount -gt 0) { $text = ($rows[0..($rowCount - 1)] -join "`n") + "`n" }
            Set-Registry $f $text
            $rid = ''; $profile = ''
            if ($rowCount -ge 2) { $rid = $f.Identity.Id }
            if ($rowCount -ge 3) { $profile = $f.Profile }
            Assert-Info $f (Call-Bind $f 'info') 'registry-bad' 1 $true $rid $profile @("registry_lines=$rowCount")
        }
    }
    Case 'registry-empty-middle-line-is-not-discarded' {
        $f = New-Fixture
        Set-Registry $f ($f.Identity.Normalized + "`n`n" + $f.Identity.Id + "`n" + $f.Profile + "`n")
        Assert-Info $f (Call-Bind $f 'info') 'registry-bad' 1 $true '' $f.Identity.Id @('registry_lines=4')
    }
    Case 'registry-empty-project-id' {
        $f = New-Fixture
        Set-Registry $f ($f.Identity.Normalized + "`n`n" + $f.Profile + "`n")
        Assert-Info $f (Call-Bind $f 'info') 'registry-bad' 1 $true '' $f.Profile @('registry_lines=3', 'reason=project-id')
    }
    Case 'registry-directory-mismatch-precedes-project-id' {
        $f = New-Fixture
        $wrong = $f.Identity.Normalized + '-other'
        Set-Registry $f ($wrong + "`nwrong-id`n" + $f.Profile + "`n")
        Assert-Info $f (Call-Bind $f 'info') 'registry-mismatch' 1 $true 'wrong-id' $f.Profile @("registry_dir=$wrong")
    }
    Case 'registry-wrong-id' {
        $f = New-Fixture
        Set-Registry $f ($f.Identity.Normalized + "`nwrong-id`n" + $f.Profile + "`n")
        Assert-Info $f (Call-Bind $f 'info') 'registry-bad' 1 $true 'wrong-id' $f.Profile @('registry_lines=3', 'reason=project-id')
    }
    Case 'registry-trim-crlf-bom-and-trailing-empty-lines' {
        $f = New-Fixture
        Write-Text $f.Profile ([string][char]0xFEFF + "正文`r`n## 启用要点`r`nstatus=not-a-protocol`r`n")
        Set-Registry $f ([string][char]0xFEFF + '  ' + $f.Identity.Normalized + " `r`n " + $f.Identity.Id + " `r`n " + $f.Profile + " `r`n`r`n`r`n")
        $before = [IO.File]::ReadAllBytes($f.Identity.Registry)
        Assert-Info $f (Call-Bind $f 'info') 'ok' 0 $true $f.Identity.Id $f.Profile
        Assert-Bytes $f.Identity.Registry $before
    }
    Case 'profile-missing' {
        $f = New-Fixture; Valid-Registry $f
        Assert-Info $f (Call-Bind $f 'info') 'profile-missing' 1 $true $f.Identity.Id $f.Profile
    }
    Case 'profile-section-exact-match' {
        $f = New-Fixture; Valid-Registry $f
        Write-Text $f.Profile "### 启用要点`n## 启用要点 `n ## 启用要点`n"
        Assert-Info $f (Call-Bind $f 'info') 'profile-no-section' 1 $true $f.Identity.Id $f.Profile
        Write-Text $f.Profile '## 启用要点'
        Assert-Info $f (Call-Bind $f 'info') 'ok' 0 $true $f.Identity.Id $f.Profile
    }
    foreach ($kind in @('drive-relative', 'root-relative', 'relative', 'device', 'extended-device', 'ads', 'unc-incomplete')) {
        Case ('invalid-path-' + $kind) {
            $f = New-Fixture
            $drive = [IO.Path]::GetPathRoot($f.Root).Substring(0, 2)
            $bad = switch ($kind) {
                'drive-relative' { $drive + 'relative.md' }
                'root-relative' { '\root-relative.md' }
                'relative' { 'relative.md' }
                'device' { '\\.\NUL' }
                'extended-device' { '\\?\' + $f.Profile }
                'ads' { $f.Profile + ':stream' }
                'unc-incomplete' { '\\server-only' }
            }
            foreach ($parameter in @('WorkDir', 'ConfigRoot', 'SkillDir', 'ProfilePath')) {
                $values = @{ WorkDir = $f.Work; ConfigRoot = $f.Config; SkillDir = $f.Skill; ProfilePath = $f.Profile }
                $values[$parameter] = $bad
                $argv = @('-Action', 'check-profile')
                foreach ($key in @('WorkDir', 'ConfigRoot', 'SkillDir', 'ProfilePath')) { $argv += @('-' + $key, $values[$key]) }
                Assert-Failure (Invoke-Bind $argv) 'usage' 2
            }
            Valid-Registry $f $bad
            Assert-Info $f (Call-Bind $f 'info') 'registry-bad' 1 $true $f.Identity.Id $bad @('registry_lines=3', 'reason=profile-path')
            Assert-NoTemps $f
        }
    }
    Case 'registry-empty-profile-line-count' {
        $f = New-Fixture
        Set-Registry $f ($f.Identity.Normalized + "`n" + $f.Identity.Id + "`n`n")
        Assert-Info $f (Call-Bind $f 'info') 'registry-bad' 1 $true $f.Identity.Id '' @('registry_lines=2')
    }
    Case 'existing-directory-is-not-profile-file' {
        $f = New-Fixture
        Assert-Failure (Call-Bind $f 'check-profile' @('-ProfilePath', $f.Root)) 'usage' 2
        Assert-Failure (Call-Bind $f 'write-registry' @('-ProfilePath', $f.Root)) 'usage' 2
        Valid-Registry $f $f.Root
        Assert-Info $f (Call-Bind $f 'info') 'registry-bad' 1 $true $f.Identity.Id $f.Root @('registry_lines=3', 'reason=profile-path')
    }
    Case 'missing-workdir-and-file-instead-of-workdir' {
        $f = New-Fixture
        Write-Text $f.Profile 'file'
        foreach ($path in @((Join-Path $f.Root 'absent'), $f.Profile)) {
            Assert-Failure (Invoke-Bind @('-Action', 'info', '-WorkDir', $path, '-ConfigRoot', $f.Config, '-SkillDir', $f.Skill)) 'usage' 2
        }
    }
    Case 'config-and-skill-must-not-be-files' {
        $f = New-Fixture
        Write-Text $f.Profile 'ordinary file'
        foreach ($parameter in @('ConfigRoot', 'SkillDir')) {
            $values = @{ ConfigRoot = $f.Config; SkillDir = $f.Skill }
            $values[$parameter] = $f.Profile
            Assert-Failure (Invoke-Bind @('-Action', 'check-profile', '-WorkDir', $f.Work, '-ProfilePath', (Join-Path $f.Root 'safe.md'), '-ConfigRoot', $values.ConfigRoot, '-SkillDir', $values.SkillDir)) 'usage' 2
        }
        Assert-NoTemps $f
    }
    Case 'registry-file-path-must-not-be-a-directory' {
        $f = New-Fixture
        [void](New-Directory $f.Identity.Registry)
        Assert-Failure (Call-Bind $f 'info') 'usage' 2
        Assert-Failure (Call-Bind $f 'write-registry' @('-ProfilePath', $f.Profile)) 'usage' 2
        Assert-True ([IO.Directory]::Exists($f.Identity.Registry)) 'Existing directory was changed'
        Assert-NoTemps $f
    }
    foreach ($reason in @('skill-dir', 'registry', 'other-project')) {
        Case ('location-' + $reason + '-case-boundary-and-no-cross-project-read') {
            $f = New-Fixture
            $blocked = switch ($reason) {
                'skill-dir' { $f.Skill }
                'registry' { Join-Path $f.Config 'tiaokong-registry' }
                'other-project' { Join-Path $f.Config 'tiaokong-projects\different-id' }
            }
            # Nonexistent blocked directory itself must already be rejected.
            foreach ($action in @('check-profile', 'write-registry')) {
                Assert-Location (Call-Bind $f $action @('-ProfilePath', $blocked.ToUpperInvariant())) 'rejected' ([IO.Path]::GetFullPath($blocked.ToUpperInvariant())) $reason
            }
            Assert-True (-not [IO.File]::Exists($f.Identity.Registry)) 'Rejected location still wrote registration'
            [void](New-Directory $blocked)
            $target = Join-Path $blocked "禁止读取' [档案].md"
            [IO.File]::WriteAllBytes($target, [byte[]]@(0xFF, 0xFE, 0x00, 0xD8))
            Valid-Registry $f $target
            $handle = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                Assert-Info $f (Call-Bind $f 'info') 'registry-bad' 1 $true $f.Identity.Id $target @('registry_lines=3', 'reason=profile-location')
            } finally { $handle.Dispose() }
            Assert-Bytes $target ([byte[]]@(0xFF, 0xFE, 0x00, 0xD8))
            # A lexical prefix is not a directory boundary.
            $safe = Join-Path ($blocked + '-prefix-trap') 'safe.md'
            if ($reason -eq 'other-project') { $safe = Join-Path ($f.Config + '-prefix-trap') 'tiaokong-projects\safe.md' }
            Assert-Location (Call-Bind $f 'check-profile' @('-ProfilePath', $safe)) 'ok' ([IO.Path]::GetFullPath($safe))
            Assert-NoTemps $f
        }
    }
    Case 'current-project-allowed-but-neighbor-prefix-rejected' {
        $f = New-Fixture
        $safe = Join-Path $f.Identity.Project "档案' [ok].md"
        Assert-Location (Call-Bind $f 'check-profile' @('-ProfilePath', $safe)) 'ok' ([IO.Path]::GetFullPath($safe))
        Assert-True (-not [IO.Directory]::Exists($f.Identity.Project)) 'check-profile created project directory'
        $wrong = Join-Path ($f.Identity.Project + '-neighbor') 'profile.md'
        Assert-Location (Call-Bind $f 'check-profile' @('-ProfilePath', $wrong)) 'rejected' ([IO.Path]::GetFullPath($wrong)) 'other-project'
        [void](New-Directory $f.Identity.Project)
        Assert-Failure (Call-Bind $f 'check-profile' @('-ProfilePath', $f.Identity.Project)) 'usage' 2
        $projects = Join-Path $f.Config 'tiaokong-projects'
        Assert-Location (Call-Bind $f 'check-profile' @('-ProfilePath', $projects)) 'rejected' ([IO.Path]::GetFullPath($projects)) 'other-project'
    }
    Case 'dotdot-rejected-before-fullpath-for-both-separators' {
        $f = New-Fixture
        foreach ($action in @('check-profile', 'write-registry')) {
            Assert-Location (Call-Bind $f $action @('-ProfilePath', 'relative/../safe.md')) 'rejected' '' 'dotdot'
        }
        foreach ($path in @((Join-Path $f.Root 'child\..\safe.md'), ($f.Root.Replace('\', '/') + '/child/../safe.md'))) {
            foreach ($action in @('check-profile', 'write-registry')) {
                Assert-Location (Call-Bind $f $action @('-ProfilePath', $path)) 'rejected' '' 'dotdot'
            }
            Valid-Registry $f $path
            Assert-Info $f (Call-Bind $f 'info') 'registry-bad' 1 $true $f.Identity.Id $path @('registry_lines=3', 'reason=profile-location')
        }
        $safe = Join-Path $f.Root 'not..dot\safe.md'
        Assert-Location (Call-Bind $f 'check-profile' @('-ProfilePath', $safe)) 'ok' ([IO.Path]::GetFullPath($safe))
        Assert-NoTemps $f
    }
    Case 'safe-location-fullpath-and-no-directory-creation' {
        $f = New-Fixture
        $safe = Join-Path $f.Root "new [dir]'\child\.\profile.md"
        Assert-Location (Call-Bind $f 'check-profile' @('-ProfilePath', $safe)) 'ok' ([IO.Path]::GetFullPath($safe))
        Assert-True (-not [IO.Directory]::Exists((Join-Path $f.Root "new [dir]'"))) 'check-profile created parent'
        Assert-NoTemps $f
    }
    Case 'written-exact-three-lines-lf-no-bom-and-exists-preserves-bytes' {
        $f = New-Fixture
        $profile = Join-Path $f.Root "new [parent]'\child\.\档案.md"
        $protocol = Assert-Protocol (Call-Bind $f 'write-registry' @('-ProfilePath', $profile)) 'written' 0
        Assert-Lines $protocol @('status=written', "registry_file=$($f.Identity.Registry)", "project_id=$($f.Identity.Id)")
        $expected = $script:Utf8.GetBytes($f.Identity.Normalized + "`n" + $f.Identity.Id + "`n" + [IO.Path]::GetFullPath($profile) + "`n")
        Assert-Bytes $f.Identity.Registry $expected
        Assert-True ([IO.Directory]::Exists((Join-Path $f.Config 'tiaokong-registry'))) 'Registry parent not created'
        Assert-True (-not [IO.Directory]::Exists($f.Identity.Project)) 'write-registry created project directory'
        Assert-True (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($profile))) 'write-registry created profile parent'
        Assert-True (-not [IO.File]::Exists($profile)) 'write-registry created profile'
        $original = [byte[]]@(0xEF, 0xBB, 0xBF, 0xFF, 0x0D, 0x0A, 0x23, 0x00)
        [IO.File]::WriteAllBytes($f.Identity.Registry, $original)
        $protocol = Assert-Protocol (Call-Bind $f 'write-registry' @('-ProfilePath', $f.Profile)) 'exists' 1
        Assert-Lines $protocol @('status=exists', "registry_file=$($f.Identity.Registry)", "project_id=$($f.Identity.Id)")
        Assert-Bytes $f.Identity.Registry $original
        Assert-NoTemps $f
    }
    Case 'write-does-not-validate-profile-content' {
        $f = New-Fixture
        [IO.File]::WriteAllBytes($f.Profile, [byte[]]@(0xFF))
        [void](Assert-Protocol (Call-Bind $f 'write-registry' @('-ProfilePath', $f.Profile)) 'written' 0)
        Assert-Bytes $f.Profile ([byte[]]@(0xFF))
        Assert-Bytes $f.Identity.Registry ($script:Utf8.GetBytes($f.Identity.Normalized + "`n" + $f.Identity.Id + "`n" + $f.Profile + "`n"))
        Assert-NoTemps $f
    }
    Case 'write-missing-config-is-error-not-exists' {
        $f = New-Fixture
        $f.Config = Join-Path $f.Root 'missing-config'; $f.Identity = Identity $f.Work $f.Config
        Assert-Failure (Call-Bind $f 'write-registry' @('-ProfilePath', $f.Profile)) 'error' 3
        Assert-True (-not [IO.Directory]::Exists($f.Config)) 'Missing ConfigRoot was created'
        Assert-NoTemps $f
    }
    Case 'registry-io-failure-is-error-not-not-bound' {
        $f = New-Fixture; Valid-Registry $f
        $before = [IO.File]::ReadAllBytes($f.Identity.Registry)
        $handle = [IO.File]::Open($f.Identity.Registry, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { Assert-Failure (Call-Bind $f 'info') 'error' 3 }
        finally { $handle.Dispose() }
        Assert-Bytes $f.Identity.Registry $before
        Assert-NoTemps $f
    }
    Case 'profile-io-failure-is-error-not-missing-or-no-section' {
        $f = New-Fixture; Valid-Registry $f
        Write-Text $f.Profile "## 启用要点`n正文`n"
        $before = [IO.File]::ReadAllBytes($f.Profile)
        $handle = [IO.File]::Open($f.Profile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { Assert-Failure (Call-Bind $f 'info') 'error' 3 }
        finally { $handle.Dispose() }
        Assert-Bytes $f.Profile $before
        Assert-NoTemps $f
    }
    Case 'strict-utf8-registry-and-profile-no-writeback' {
        $f = New-Fixture; Valid-Registry $f
        $bad = [byte[]]@(0xC3, 0x28)
        [IO.File]::WriteAllBytes($f.Identity.Registry, $bad)
        Assert-Failure (Call-Bind $f 'info') 'error' 3
        Assert-Bytes $f.Identity.Registry $bad
        Valid-Registry $f
        [IO.File]::WriteAllBytes($f.Profile, [byte[]]@(0xFF, 0xFE, 0x23, 0x00))
        Assert-Failure (Call-Bind $f 'info') 'error' 3
        Assert-Bytes $f.Profile ([byte[]]@(0xFF, 0xFE, 0x23, 0x00))
        Assert-NoTemps $f
    }
    Case 'write-permission-failure-is-error-not-exists-and-no-temp-residue' {
        $f = New-Fixture
        $directory = New-Directory (Join-Path $f.Config 'tiaokong-registry')
        $acl = Get-Acl -LiteralPath $directory
        $originalSddl = $acl.Sddl
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]::CreateFiles, [Security.AccessControl.AccessControlType]::Deny)
        try {
            [void]$acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $directory -AclObject $acl
            Assert-Failure (Call-Bind $f 'write-registry' @('-ProfilePath', $f.Profile)) 'error' 3
        } finally {
            $restore = New-Object Security.AccessControl.DirectorySecurity
            $restore.SetSecurityDescriptorSddlForm($originalSddl)
            Set-Acl -LiteralPath $directory -AclObject $restore
        }
        Assert-True (-not [IO.File]::Exists($f.Identity.Registry)) 'Failed write left a registry'
        Assert-True (-not [IO.Directory]::Exists($f.Identity.Project)) 'Failed write created project'
        Assert-NoTemps $f
    }
} catch {
    $script:Failed++
    [Console]::WriteLine('FAIL harness: ' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' '))
} finally {
    foreach ($child in @($script:Children.ToArray())) {
        try { Stop-OwnedProcess $child; $child.Dispose() }
        catch { $script:Failed++; [Console]::WriteLine('FAIL process-cleanup: ' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' ')) }
    }
    if ($null -ne $script:OwnedRoot) {
        try {
            Remove-Item -LiteralPath $script:OwnedRoot -Recurse -Force
            Assert-True (-not [IO.Directory]::Exists($script:OwnedRoot)) 'Owned fixture directory remains'
        } catch { $script:Failed++; [Console]::WriteLine('FAIL fixture-cleanup: ' + $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' ')) }
    }
}
[Console]::WriteLine("summary pass=$script:Passed fail=$script:Failed")
if ($script:Failed -gt 0) { exit 1 }
exit 0
