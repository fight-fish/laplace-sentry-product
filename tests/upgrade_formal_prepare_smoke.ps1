[CmdletBinding()]
param()

<#
.SYNOPSIS
Proves PrepareFormal under isolated TEMP fixtures and the read-only production WSL metadata seam.

.DESCRIPTION
Purpose: exercise prepare success, rejection, interruption, reentry, integrity sealing, the zero-formal-write boundary, and production WSL stat argument handling.
Inputs: fixed Git objects, generated mixed Frontend/Backend targets and observation JSON below system TEMP, plus formal backend main.py as a read-only metadata witness.
Outputs: one PASS/FAIL result; all fixture evidence is removed before exit.
SSOT Output: process exit code; zero means every prepare-only assertion passed.
Exit codes: 0 pass, 1 assertion, boundary, script, or cleanup failure.
SKIP conditions: none.
FAIL conditions: any wrong exit/result/state/count/hash/reentry/boundary result, TEMP residue, or production metadata command/parser result.
Order-sensitive checks: formal-boundary and fixture target snapshots are captured before prepare and compared after every case.
Side effects: creates and removes only verified strict children of system TEMP and issues read-only WSL stat calls; never invokes live PrepareFormal, upgrade.bat, Git writes, processes, registry, or runtime changes.
#>

# 這支腳本在做什麼：用 TEMP 假目標證明完整 prepare 契約，並唯讀走過 production WSL metadata 接縫。
# 這支腳本不做什麼：不執行真實 prepare、不建立正式 transaction root，也不測 apply／repair／rollback。
# 常改區塊：production metadata 接縫、拒絕案例、故障注入、manifest 與重入斷言。
# 不要亂動的區塊：正式邊界前後 fingerprint、嚴格 TEMP 清理與 0 formal target writes。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$UpgradeScript = Join-Path $RepoRoot 'scripts\upgrade.ps1'
$UpgradeBat = Join-Path $RepoRoot 'upgrade.bat'
$TempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$SuiteRoot = Join-Path $TempBase ('LaplaceSentryFormalPrepareSmoke-' + [Guid]::NewGuid().ToString('N'))
$OutsideRoot = Join-Path $TempBase ('LaplaceSentryFormalPrepareOutside-' + [Guid]::NewGuid().ToString('N'))
$TemplateRoot = Join-Path $SuiteRoot '_template'
$FormalFrontend = Join-Path $env:LOCALAPPDATA 'LaplaceSentry'
$FormalBackend = '\\wsl.localhost\Ubuntu\home\serpal\.laplace_sentry_backend'
$FormalBackendLinux = '/home/serpal/.laplace_sentry_backend'
$FormalTransactions = Join-Path $env:LOCALAPPDATA 'LaplaceSentryUpgrade'
$TargetCommit = '971ba498d613c2bb20d46e14855cc0b0a326602a'
$AdapterCommit = '4f228ae5f31754aa43a918274e3b542b6f0a2144'
$SourceMarker = '1e7bc2b'
$FixedTime = [DateTime]::Parse('2024-01-02T03:04:05.0000000Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
$FrontendAllowlist = @('assets', 'src', 'requirements.txt', 'run_ui.bat', 'run_ui.vbs', 'run_dev_ui.bat')
$BackendAllowlist = @('main.py', 'requirements.txt', 'src')
$JunctionPath = $null

# 直接載入純 basis 判定，才能在不寫入 repo Git 的前提下模擬合法 checkpoint。
. (Join-Path $RepoRoot 'scripts\upgrade_formal_prepare.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "[ASSERT_FAIL] $Message" }
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $caught = $null
    try { & $Action }
    catch { $caught = $_ }
    $actual = if ($null -ne $caught) { $caught.Exception.Message } else { '<no exception>' }
    Assert-True ($null -ne $caught -and $actual -match $Pattern) "$Message Actual=$actual"
}

function Assert-ProductionWslMetadataSeam {
    $relativePath = 'main.py'
    $windowsPath = Join-Path $FormalBackend $relativePath
    $linuxPath = "$FormalBackendLinux/$relativePath"
    Assert-True (Test-Path -LiteralPath $windowsPath -PathType Leaf) "Formal backend witness is unavailable: $windowsPath"

    $direct = @(& wsl.exe -d Ubuntu --exec stat -c '%a|%u|%g|%F' -- $linuxPath 2>$null)
    $directExit = $LASTEXITCODE
    Assert-True ($directExit -eq 0 -and $direct.Count -eq 1) "Literal argv control failed. exit=$directExit count=$($direct.Count)"
    Assert-True ($direct[0] -match '^(\d+)\|(\d+)\|(\d+)\|regular file$') "Literal argv control returned malformed metadata: $($direct -join ';')"
    $expectedMode = $Matches[1]
    $expectedUid = [int]$Matches[2]
    $expectedGid = [int]$Matches[3]

    $metadata = Get-FormalPrepareFileMetadata -Side 'Backend' -RelativePath $relativePath -Path $windowsPath -Observation ([pscustomobject]@{}) -FixtureMode $false
    Assert-True ($metadata.exists -and $metadata.posix_mode -eq $expectedMode -and $metadata.uid -eq $expectedUid -and $metadata.gid -eq $expectedGid) 'Production metadata helper diverged from the literal argv control.'

    $missing = "/tmp/LaplaceSentryWslMetadataMissing-$([Guid]::NewGuid().ToString('N'))"
    Assert-ThrowsLike { Get-FormalPrepareWslFileMetadata -LinuxPath $missing } 'UPGRADE_PREPARE_SOURCE_FAIL' 'A failed production stat command was accepted.'
    Assert-ThrowsLike { Get-FormalPrepareWslFileMetadata -LinuxPath '/tmp' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'A non-regular WSL path was accepted.'
    Assert-ThrowsLike { ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000') -ExitCode 0 -LinuxPath '/synthetic/incomplete' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'Incomplete metadata was accepted.'
    Assert-ThrowsLike { ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000|directory') -ExitCode 0 -LinuxPath '/synthetic/directory' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'Malformed file type metadata was accepted.'
    Assert-ThrowsLike { ConvertFrom-FormalPrepareWslStat -StatOutput @('755|1000|1000|regular file', 'extra') -ExitCode 0 -LinuxPath '/synthetic/multiple' } 'UPGRADE_PREPARE_SOURCE_FAIL' 'Multiple metadata lines were accepted.'
}

function Assert-CheckpointBasisContract {
    $syntheticHead = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $priorRepoHead = '3f3321046a0f32691ca63ad67c887f32188b7ffc'
    $expectedPaths = @('scripts/upgrade_formal_prepare.ps1', 'tests/upgrade_formal_prepare_smoke.ps1')
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $FormalPrepareRepoHead -ParentHead '' -ChangedPaths @()) -eq 'working_tree') 'Original working-tree basis was rejected.'
    Assert-True ((Assert-FormalPrepareCheckpointBasis -CurrentHead $syntheticHead -ParentHead $FormalPrepareRepoHead -ChangedPaths $expectedPaths) -eq 'checkpoint') 'Legal direct two-file checkpoint was rejected.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticHead -ParentHead $priorRepoHead -ChangedPaths (@('scripts/upgrade.ps1') + $expectedPaths))) 'Prior three-file checkpoint lineage was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticHead -ParentHead ('b' * 40) -ChangedPaths $expectedPaths)) 'Wrong checkpoint parent was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticHead -ParentHead $FormalPrepareRepoHead -ChangedPaths @('scripts/upgrade_formal_prepare.ps1'))) 'Partial checkpoint was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticHead -ParentHead $FormalPrepareRepoHead -ChangedPaths (@('scripts/upgrade.ps1') + $expectedPaths))) 'Checkpoint with an unapproved prior-work path was accepted.'
    Assert-True (-not (Test-FormalPrepareCheckpointShape -CurrentHead $syntheticHead -ParentHead $FormalPrepareRepoHead -ChangedPaths ($expectedPaths + 'fourth-file.txt'))) 'Checkpoint with a fourth file was accepted.'
}

function Assert-StrictTempPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    Assert-True ($resolved.StartsWith($TempBase + '\', [StringComparison]::OrdinalIgnoreCase)) "Path escaped system TEMP: $resolved"
}

function Remove-TestTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-StrictTempPath $Path
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

function Get-Sha {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Quote-Argument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-ExpectedManagedPaths {
    $specs = @($FrontendAllowlist | ForEach-Object { 'Frontend/' + $_ }) + @($BackendAllowlist | ForEach-Object { 'Backend/' + $_ })
    $paths = @(& git -C $RepoRoot ls-tree -r --name-only $TargetCommit -- @specs)
    Assert-True ($LASTEXITCODE -eq 0) 'Unable to enumerate target package paths.'
    return @($paths | Where-Object { $_ -and $_ -notmatch '(^|/)(__pycache__|\.venv)(/|$)' -and $_ -notmatch '\.pyc$' } | Sort-Object -Unique)
}

function Export-CommitTree {
    param([string]$Commit, [string[]]$PathSpecs, [string]$Destination, [string]$WorkRoot)
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    $archive = Join-Path $WorkRoot 'tree.zip'
    & git -C $RepoRoot archive --format=zip "--output=$archive" $Commit -- @PathSpecs
    Assert-True ($LASTEXITCODE -eq 0) "git archive failed for $Commit."
    Expand-Archive -LiteralPath $archive -DestinationPath $Destination -Force
    Remove-Item -LiteralPath $archive -Force
}

function Initialize-PrepareTemplate {
    $build = Join-Path $TemplateRoot 'fixture-build'
    $tree = Join-Path $build 'target'
    $oldTree = Join-Path $build 'old-adapter'
    New-Item -ItemType Directory -Path $TemplateRoot -Force | Out-Null
    $specs = @($FrontendAllowlist | ForEach-Object { 'Frontend/' + $_ }) + @($BackendAllowlist | ForEach-Object { 'Backend/' + $_ })
    Export-CommitTree -Commit $TargetCommit -PathSpecs $specs -Destination $tree -WorkRoot (Join-Path $build 'target-archive')
    Export-CommitTree -Commit $AdapterCommit -PathSpecs @('Frontend/src/backend/adapter.py') -Destination $oldTree -WorkRoot (Join-Path $build 'old-archive')
    $frontend = Join-Path $TemplateRoot 'frontend-target'
    $backend = Join-Path $TemplateRoot 'backend-target'
    Move-Item -LiteralPath (Join-Path $tree 'Frontend') -Destination $frontend
    Move-Item -LiteralPath (Join-Path $tree 'Backend') -Destination $backend
    Copy-Item -LiteralPath (Join-Path $oldTree 'Frontend\src\backend\adapter.py') -Destination (Join-Path $frontend 'src\backend\adapter.py') -Force
    Remove-TestTree $build
    New-Item -ItemType Directory -Path (Join-Path $backend 'data') -Force | Out-Null
    "[General]`r`neye_size=480" | Set-Content -LiteralPath (Join-Path $frontend 'sentry_config.ini') -Encoding UTF8
    '[{"uuid":"fixture-project","name":"must-survive"}]' | Set-Content -LiteralPath (Join-Path $backend 'data\projects.json') -Encoding UTF8
    $SourceMarker | Set-Content -LiteralPath (Join-Path $frontend 'version.txt') -Encoding ASCII -NoNewline
    $SourceMarker | Set-Content -LiteralPath (Join-Path $backend 'version.txt') -Encoding ASCII -NoNewline
    $observation = Join-Path $TemplateRoot 'observation.json'
    [ordered]@{
        source_dirty = $false
        tracked_deletions = @()
        requirements_changes = @()
        force_non_ancestor = $false
        protected_unreadable = @()
        ambiguous_runtime = @()
        lock_exists = $false
        ui = @()
        daemon = @()
        workers = @()
        registry = @([ordered]@{ pid = 114348; uuid = 'fixture-stale'; proc_exists = $false; owned = $false; uuid_matches = $false; ambiguous = $false })
        transaction_acl_ok = $true
        transaction_owner_ok = $true
        free_bytes = [int64](4GB)
        fixture_backend_mode = '755'
        fixture_backend_uid = 1000
        fixture_backend_gid = 1000
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $observation -Encoding UTF8
    foreach ($file in @(Get-ChildItem -LiteralPath $frontend, $backend -Recurse -File -Force)) { [IO.File]::SetLastWriteTimeUtc($file.FullName, $FixedTime) }
    [IO.File]::SetLastWriteTimeUtc($observation, $FixedTime)
}

function New-PrepareCase {
    param([Parameter(Mandatory = $true)][string]$Name)
    $root = Join-Path $SuiteRoot $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $TemplateRoot 'frontend-target') -Destination (Join-Path $root 'frontend-target') -Recurse
    Copy-Item -LiteralPath (Join-Path $TemplateRoot 'backend-target') -Destination (Join-Path $root 'backend-target') -Recurse
    Copy-Item -LiteralPath (Join-Path $TemplateRoot 'observation.json') -Destination (Join-Path $root 'observation.json')
    $frontend = Join-Path $root 'frontend-target'
    $backend = Join-Path $root 'backend-target'
    $observation = Join-Path $root 'observation.json'
    $case = [pscustomobject]@{
        Name = $Name
        Root = $root
        Frontend = $frontend
        Backend = $backend
        Transactions = Join-Path $root 'transactions'
        Observation = $observation
        Adapter = Join-Path $frontend 'src\backend\adapter.py'
        Tray = Join-Path $frontend 'src\tray\tray_app.py'
        FrontendMarker = Join-Path $frontend 'version.txt'
        BackendMarker = Join-Path $backend 'version.txt'
        Config = Join-Path $frontend 'sentry_config.ini'
        Projects = Join-Path $backend 'data\projects.json'
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $frontend, $backend -Recurse -File -Force)) { [IO.File]::SetLastWriteTimeUtc($file.FullName, $FixedTime) }
    [IO.File]::SetLastWriteTimeUtc($observation, $FixedTime)
    return $case
}

function Write-CaseObservation {
    param([Parameter(Mandatory = $true)]$Case, [Parameter(Mandatory = $true)]$Observation)
    $Observation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Case.Observation -Encoding UTF8
    [IO.File]::SetLastWriteTimeUtc($Case.Observation, $FixedTime)
}

function Get-CaseTargetCanonical {
    param([Parameter(Mandatory = $true)]$Case)
    $lines = @()
    foreach ($gitPath in Get-ExpectedManagedPaths) {
        $side = if ($gitPath.StartsWith('Frontend/')) { 'Frontend' } else { 'Backend' }
        $relative = $gitPath.Substring($side.Length + 1)
        $root = if ($side -eq 'Frontend') { $Case.Frontend } else { $Case.Backend }
        $path = Join-Path $root $relative.Replace('/', '\')
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item = Get-Item -LiteralPath $path -Force
            $lines += "$gitPath|1|$($item.Length)|$($item.LastWriteTimeUtc.ToString('o'))|$(Get-Sha $path)"
        }
        else { $lines += "$gitPath|0|-|-|-" }
    }
    foreach ($spec in @(
        @('Frontend/version.txt', $Case.FrontendMarker), @('Backend/version.txt', $Case.BackendMarker),
        @('Frontend/sentry_config.ini', $Case.Config), @('Backend/data/projects.json', $Case.Projects)
    )) {
        $item = Get-Item -LiteralPath $spec[1] -Force
        $lines += "$($spec[0])|1|$($item.Length)|$($item.LastWriteTimeUtc.ToString('o'))|$(Get-Sha $spec[1])"
    }
    return @($lines | Sort-Object) -join "`n"
}

function Get-TreeCanonical {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'ABSENT' }
    $lines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($Path.Length).TrimStart('\').Replace('\', '/')
        $lines += "$relative|$($file.Length)|$($file.LastWriteTimeUtc.ToString('o'))|$(Get-Sha $file.FullName)"
    }
    return @($lines) -join "`n"
}

function Get-FormalBoundaryCanonical {
    $parts = @()
    foreach ($gitPath in Get-ExpectedManagedPaths) {
        $side = if ($gitPath.StartsWith('Frontend/')) { 'Frontend' } else { 'Backend' }
        $relative = $gitPath.Substring($side.Length + 1)
        $root = if ($side -eq 'Frontend') { $FormalFrontend } else { $FormalBackend }
        $path = Join-Path $root $relative.Replace('/', '\')
        try {
            if ($side -eq 'Backend') {
                $linuxPath = '/home/serpal/.laplace_sentry_backend/' + $relative
                & wsl.exe -d Ubuntu -- test -f $linuxPath
                if ($LASTEXITCODE -eq 0) {
                    $stat = @(& wsl.exe -d Ubuntu -- stat -c '%s' -- $linuxPath)
                    $hash = @(& wsl.exe -d Ubuntu -- sha256sum -- $linuxPath)
                    Assert-True ($LASTEXITCODE -eq 0 -and $stat.Count -eq 1 -and $hash.Count -eq 1) "Unable to hash formal backend path: $linuxPath"
                    $parts += "$gitPath|1|$($stat[0].Trim())|$((($hash[0] -split '\s+')[0]).ToUpperInvariant())"
                }
                else { $parts += "$gitPath|0|-|-" }
            }
            elseif (Test-Path -LiteralPath $path -PathType Leaf) {
                $item = Get-Item -LiteralPath $path -Force
                $parts += "$gitPath|1|$($item.Length)|$(Get-Sha $path)"
            }
            else { $parts += "$gitPath|0|-|-" }
        }
        catch { throw "Formal boundary read failed for $gitPath at $path`: $($_.Exception.Message)" }
    }
    foreach ($spec in @(
        @('Frontend/version.txt', (Join-Path $FormalFrontend 'version.txt')),
        @('Frontend/sentry_config.ini', (Join-Path $FormalFrontend 'sentry_config.ini')),
        @('Backend/version.txt', '/home/serpal/.laplace_sentry_backend/version.txt'),
        @('Backend/data/projects.json', '/home/serpal/.laplace_sentry_backend/data/projects.json')
    )) {
        if ($spec[0].StartsWith('Backend/')) {
            & wsl.exe -d Ubuntu -- test -f $spec[1]
            if ($LASTEXITCODE -eq 0) {
                $stat = @(& wsl.exe -d Ubuntu -- stat -c '%s' -- $spec[1])
                $hash = @(& wsl.exe -d Ubuntu -- sha256sum -- $spec[1])
                Assert-True ($LASTEXITCODE -eq 0 -and $stat.Count -eq 1 -and $hash.Count -eq 1) "Unable to hash formal backend protected path: $($spec[1])"
                $parts += "$($spec[0])|1|$($stat[0].Trim())|$((($hash[0] -split '\s+')[0]).ToUpperInvariant())"
            }
            else { $parts += "$($spec[0])|0|-|-" }
        }
        elseif (Test-Path -LiteralPath $spec[1] -PathType Leaf) {
            $item = Get-Item -LiteralPath $spec[1] -Force
            $parts += "$($spec[0])|1|$($item.Length)|$(Get-Sha $spec[1])"
        }
        else { $parts += "$($spec[0])|0|-|-" }
    }
    $parts += "formal-transactions|$(Get-TreeCanonical $FormalTransactions)"
    return @($parts | Sort-Object) -join "`n"
}

function Invoke-PrepareProcess {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [string]$Injection = 'None',
        [string]$Frontend = $Case.Frontend,
        [string]$Backend = $Case.Backend,
        [string]$Transactions = $Case.Transactions,
        [string]$Observation = $Case.Observation,
        [string]$IsolationRoot = $Case.Root
    )
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Argument $UpgradeScript),
        '-Mode', 'PrepareFormal',
        '-IsolationRoot', (Quote-Argument $IsolationRoot),
        '-TransactionRoot', (Quote-Argument $Transactions),
        '-FrontendTarget', (Quote-Argument $Frontend),
        '-BackendTarget', (Quote-Argument $Backend),
        '-PreflightObservationPath', (Quote-Argument $Observation),
        '-MixedFailureInjection', $Injection
    ) -join ' '
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        try { $json = $stdout.Trim() | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "[$($Case.Name)] stdout was not one JSON document. stdout=$stdout stderr=$stderr" }
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Json = $json; Stdout = $stdout; Stderr = $stderr }
}

function Assert-NoTransactionDirectory {
    param([Parameter(Mandatory = $true)]$Case)
    $count = if (Test-Path -LiteralPath $Case.Transactions) { @(Get-ChildItem -LiteralPath $Case.Transactions -Directory -Force).Count } else { 0 }
    Assert-True ($count -eq 0) "[$($Case.Name)] rejection created a transaction directory."
}

function Assert-RejectedBeforeTransaction {
    param([string]$Name, [scriptblock]$Mutate, [hashtable]$InvokeOverrides = @{})
    $case = New-PrepareCase $Name
    $observation = Get-Content -LiteralPath $case.Observation -Raw -Encoding UTF8 | ConvertFrom-Json
    & $Mutate $case $observation
    Write-CaseObservation -Case $case -Observation $observation
    $before = Get-CaseTargetCanonical $case
    $parameters = @{ Case = $case }
    foreach ($key in $InvokeOverrides.Keys) { $parameters[$key] = $InvokeOverrides[$key] }
    $result = Invoke-PrepareProcess @parameters
    Assert-True ($result.ExitCode -eq 6) "[$Name] expected exit 6. stderr=$($result.Stderr)"
    Assert-True ($result.Json.result -eq 'failed' -and $result.Json.state -eq 'rejected') "[$Name] pre-transaction result was not an explicit rejection."
    Assert-True ($result.Json.failure_phase -eq 'before_transaction' -and -not $result.Json.transaction_id -and -not $result.Json.transaction_root) "[$Name] rejection exposed the wrong transaction phase."
    Assert-NoTransactionDirectory $case
    Assert-True ((Get-CaseTargetCanonical $case) -ceq $before) "[$Name] changed fixture targets."
}

function Assert-InvalidatedZeroWrites {
    param([string]$Name, [string]$Injection)
    $case = New-PrepareCase $Name
    $before = Get-CaseTargetCanonical $case
    $result = Invoke-PrepareProcess -Case $case -Injection $Injection
    Assert-True ($result.ExitCode -eq 6) "[$Name] expected exit 6 for $Injection. stderr=$($result.Stderr)"
    Assert-True ((Get-CaseTargetCanonical $case) -ceq $before) "[$Name] changed fixture targets."
    $journals = @(Get-ChildItem -LiteralPath $case.Transactions -Recurse -File -Filter 'transaction-journal.json')
    Assert-True ($journals.Count -eq 1) "[$Name] did not preserve one journal."
    $journal = Get-Content -LiteralPath $journals[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($journal.state -eq 'prepare_invalidated') "[$Name] state was not prepare_invalidated."
    Assert-True ($result.Json.state -eq $journal.state -and $result.Json.result -eq $journal.result) "[$Name] stdout state/result diverged from journal."
    Assert-True ($result.Json.failure_phase -eq 'after_transaction' -and $result.Json.failure_phase -eq $journal.failure_phase) "[$Name] stdout did not identify an after-transaction failure."
    Assert-True ($result.Json.transaction_id -eq $journal.transaction_id -and $result.Json.transaction_root -eq $journal.transaction_root) "[$Name] stdout transaction identity diverged from journal."
    Assert-True ($result.Json.error -eq $journal.error) "[$Name] stdout error diverged from journal."
    Assert-True ([int]$journal.formal_target_write_count -eq 0) "[$Name] formal write count was not zero."
}

try {
    Assert-CheckpointBasisContract
    Assert-StrictTempPath $SuiteRoot
    Assert-StrictTempPath $OutsideRoot
    New-Item -ItemType Directory -Path $SuiteRoot, $OutsideRoot -Force | Out-Null
    Initialize-PrepareTemplate
    $formalBefore = @(Get-FormalBoundaryCanonical) -join "`n"
    Assert-ProductionWslMetadataSeam

    $success = New-PrepareCase 'success-and-rerun'
    $targetBefore = Get-CaseTargetCanonical $success
    $prepared = Invoke-PrepareProcess -Case $success
    Assert-True ($prepared.ExitCode -eq 0 -and $prepared.Json.result -eq 'prepared') "Success prepare failed. stderr=$($prepared.Stderr)"
    Assert-True ($prepared.Json.state -eq 'prepared_pending_apply' -and [int]$prepared.Json.formal_target_write_count -eq 0) 'Success state/write count mismatch.'
    Assert-True ((Get-CaseTargetCanonical $success) -ceq $targetBefore) 'Success prepare changed fixture targets.'
    $transactionDirs = @(Get-ChildItem -LiteralPath $success.Transactions -Directory -Force)
    Assert-True ($transactionDirs.Count -eq 1) 'Success did not create exactly one transaction.'
    $journal = Get-Content -LiteralPath (Join-Path $transactionDirs[0].FullName 'transaction-journal.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourceManifest = Get-Content -LiteralPath $journal.manifests.source.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $preimageManifest = Get-Content -LiteralPath $journal.manifests.preimage.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $packageManifest = Get-Content -LiteralPath $journal.manifests.package.path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($journal.schema -eq 'laplace-formal-prepare-v1') 'Journal schema mismatch.'
    Assert-True (@($sourceManifest.records).Count -eq 31) 'Source manifest must contain 30 target records plus runtime observation.'
    Assert-True (@($preimageManifest.records).Count -eq 30) 'Preimage manifest must contain 30 records.'
    Assert-True (@($packageManifest.records).Count -eq 28) 'Package manifest must contain 26 files and two markers.'
    $frontendMetadata = @($sourceManifest.records | Where-Object { $_.key -eq 'Frontend/src/tray/tray_app.py' })[0]
    $backendMetadata = @($sourceManifest.records | Where-Object { $_.key -eq 'Backend/src/core/daemon.py' })[0]
    Assert-True ($frontendMetadata.attributes -and $frontendMetadata.sddl) 'Frontend attributes/SDDL were not sealed.'
    Assert-True ($backendMetadata.posix_mode -eq '755' -and $backendMetadata.uid -eq 1000 -and $backendMetadata.gid -eq 1000) 'Backend POSIX metadata was not sealed.'
    $runtimeEvidence = @($sourceManifest.records | Where-Object { $_.key -eq 'Runtime/observation.json' })[0]
    Assert-True ($runtimeEvidence.sha256 -and $runtimeEvidence.observation.registry.Count -eq 1) 'Runtime/registry observation was not sealed.'
    Assert-True (@($journal.warnings | Where-Object { $_.tag -eq '[UPGRADE_REGISTRY_STALE]' }).Count -eq 1) 'Stale registry warning was not preserved.'
    Assert-True (@(Get-ChildItem -LiteralPath $success.Frontend, $success.Backend -Recurse -File -Filter '*.tmp').Count -eq 0) 'Adjacent target temp file exists.'
    $transactionBeforeRerun = Get-TreeCanonical $success.Transactions
    $already = Invoke-PrepareProcess -Case $success
    Assert-True ($already.ExitCode -eq 0 -and $already.Json.result -eq 'already_prepared') 'Identical rerun was not already_prepared.'
    Assert-True ((Get-TreeCanonical $success.Transactions) -ceq $transactionBeforeRerun) 'already_prepared changed transaction evidence.'

    Assert-RejectedBeforeTransaction 'active-lock' { param($c, $o) $o.lock_exists = $true }
    Assert-RejectedBeforeTransaction 'owned-ui' { param($c, $o) $o.ui = @([pscustomobject]@{ pid = 1; owned = $true; ambiguous = $false }) }
    Assert-RejectedBeforeTransaction 'owned-daemon' { param($c, $o) $o.daemon = @([pscustomobject]@{ pid = 2; owned = $true; ambiguous = $false }) }
    Assert-RejectedBeforeTransaction 'owned-worker' { param($c, $o) $o.workers = @([pscustomobject]@{ pid = 3; owned = $true; registered = $true; ambiguous = $false }) }
    Assert-RejectedBeforeTransaction 'ambiguous-runtime' { param($c, $o) $o.registry = @([pscustomobject]@{ pid = 4; proc_exists = $true; owned = $false; uuid_matches = $false; ambiguous = $true }) }
    Assert-RejectedBeforeTransaction 'acl-reject' { param($c, $o) $o.transaction_acl_ok = $false }
    Assert-RejectedBeforeTransaction 'owner-reject' { param($c, $o) $o.transaction_owner_ok = $false }
    Assert-RejectedBeforeTransaction 'space-reject' { param($c, $o) $o.free_bytes = 1 }
    Assert-RejectedBeforeTransaction 'adapter-drift' { param($c, $o) 'drift' | Add-Content -LiteralPath $c.Adapter -Encoding UTF8 }
    Assert-RejectedBeforeTransaction 'tray-drift' { param($c, $o) 'drift' | Add-Content -LiteralPath $c.Tray -Encoding UTF8 }
    Assert-RejectedBeforeTransaction 'marker-drift' { param($c, $o) 'wrong' | Set-Content -LiteralPath $c.BackendMarker -Encoding ASCII -NoNewline }

    $overlap = New-PrepareCase 'transaction-overlap'
    $overlapResult = Invoke-PrepareProcess -Case $overlap -Transactions (Join-Path $overlap.Frontend 'transactions')
    Assert-True ($overlapResult.ExitCode -eq 6) 'Target/transaction overlap was not rejected.'
    Assert-NoTransactionDirectory $overlap
    $unc = New-PrepareCase 'transaction-unc'
    $uncResult = Invoke-PrepareProcess -Case $unc -Transactions '\\invalid-host\share\transactions'
    Assert-True ($uncResult.ExitCode -eq 6) 'UNC transaction root was not rejected.'
    Assert-NoTransactionDirectory $unc

    $reparse = New-PrepareCase 'transaction-reparse'
    $JunctionPath = Join-Path $reparse.Root 'transactions-junction'
    New-Item -ItemType Junction -Path $JunctionPath -Target $OutsideRoot | Out-Null
    $reparseResult = Invoke-PrepareProcess -Case $reparse -Transactions $JunctionPath
    Assert-True ($reparseResult.ExitCode -eq 6) 'Reparse transaction root was not rejected.'
    Assert-True (@(Get-ChildItem -LiteralPath $OutsideRoot -Force).Count -eq 0) 'Reparse rejection wrote through the junction.'

    foreach ($injection in @('Preimage', 'Package', 'Prepare', 'Journal', 'SecondSnapshot', 'EvidenceTamper')) {
        Assert-InvalidatedZeroWrites -Name ('inject-' + $injection.ToLowerInvariant()) -Injection $injection
    }

    $incomplete = New-PrepareCase 'incomplete-rerun'
    $firstIncomplete = Invoke-PrepareProcess -Case $incomplete -Injection Prepare
    Assert-True ($firstIncomplete.ExitCode -eq 6) 'Injected incomplete prepare did not fail.'
    $countBeforeIncompleteRerun = @(Get-ChildItem -LiteralPath $incomplete.Transactions -Directory -Force).Count
    $secondIncomplete = Invoke-PrepareProcess -Case $incomplete
    Assert-True ($secondIncomplete.ExitCode -eq 6 -and $secondIncomplete.Stderr -match 'UPGRADE_PREPARE_RECOVERY_REQUIRED') 'Incomplete transaction did not hard-block reentry.'
    Assert-True (@(Get-ChildItem -LiteralPath $incomplete.Transactions -Directory -Force).Count -eq $countBeforeIncompleteRerun) 'Incomplete reentry created another transaction.'

    $tamper = New-PrepareCase 'evidence-tamper-rerun'
    $tamperPrepared = Invoke-PrepareProcess -Case $tamper
    Assert-True ($tamperPrepared.ExitCode -eq 0) 'Tamper setup prepare failed.'
    $tamperJournal = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $tamper.Transactions -Recurse -File -Filter transaction-journal.json).FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $tamperPackage = Get-Content -LiteralPath $tamperJournal.manifests.package.path -Raw -Encoding UTF8 | ConvertFrom-Json
    'external-tamper' | Add-Content -LiteralPath $tamperPackage.records[0].artifact_path -Encoding UTF8
    $tamperCount = @(Get-ChildItem -LiteralPath $tamper.Transactions -Directory -Force).Count
    $tamperRerun = Invoke-PrepareProcess -Case $tamper
    Assert-True ($tamperRerun.ExitCode -eq 6 -and $tamperRerun.Stderr -match 'UPGRADE_PREPARE_RECOVERY_REQUIRED') 'Tampered evidence did not block reentry.'
    Assert-True (@(Get-ChildItem -LiteralPath $tamper.Transactions -Directory -Force).Count -eq $tamperCount) 'Tampered reentry created another transaction.'

    $multiple = New-PrepareCase 'multiple-transactions'
    $multiplePrepared = Invoke-PrepareProcess -Case $multiple
    Assert-True ($multiplePrepared.ExitCode -eq 0) 'Multiple setup prepare failed.'
    $originalTransaction = @(Get-ChildItem -LiteralPath $multiple.Transactions -Directory -Force)[0]
    Copy-Item -LiteralPath $originalTransaction.FullName -Destination (Join-Path $multiple.Transactions 'duplicate-prepared') -Recurse
    $multipleCount = @(Get-ChildItem -LiteralPath $multiple.Transactions -Directory -Force).Count
    $multipleRerun = Invoke-PrepareProcess -Case $multiple
    Assert-True ($multipleRerun.ExitCode -eq 6 -and $multipleRerun.Stderr -match 'UPGRADE_PREPARE_RECOVERY_REQUIRED') 'Multiple/corrupt prepared transactions did not block reentry.'
    Assert-True (@(Get-ChildItem -LiteralPath $multiple.Transactions -Directory -Force).Count -eq $multipleCount) 'Multiple reentry created another transaction.'

    $upgradeBatText = Get-Content -LiteralPath $UpgradeBat -Raw -Encoding UTF8
    Assert-True ($upgradeBatText -notmatch 'PrepareFormal|prepare') 'upgrade.bat publicly exposes PrepareFormal.'
    $formalAfter = @(Get-FormalBoundaryCanonical) -join "`n"
    Assert-True ($formalAfter -ceq $formalBefore) 'Formal Windows/WSL targets or formal transaction root changed.'

    Remove-TestTree $SuiteRoot
    if ($JunctionPath -and (Test-Path -LiteralPath $JunctionPath)) { Remove-Item -LiteralPath $JunctionPath -Force }
    Remove-TestTree $OutsideRoot
    Assert-True (-not (Test-Path -LiteralPath $SuiteRoot)) 'Suite TEMP residue remains.'
    Assert-True (-not (Test-Path -LiteralPath $OutsideRoot)) 'Outside TEMP residue remains.'
    Write-Output 'upgrade formal prepare smoke: PASS'
    exit 0
}
catch {
    [Console]::Error.WriteLine("upgrade formal prepare smoke: FAIL: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
    try {
        if ($JunctionPath -and (Test-Path -LiteralPath $JunctionPath)) { Remove-Item -LiteralPath $JunctionPath -Force }
        if (Test-Path -LiteralPath $SuiteRoot) { Remove-TestTree $SuiteRoot }
        if (Test-Path -LiteralPath $OutsideRoot) { Remove-TestTree $OutsideRoot }
    }
    catch { [Console]::Error.WriteLine("cleanup failure: $($_.Exception.Message)") }
    exit 1
}
