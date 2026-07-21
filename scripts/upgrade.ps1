[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Stage', 'ApplyIsolated', 'PreflightFormal', 'PrepareFormal', 'ValidateFormalApply', 'ApplyFormalFixture', 'RecoverFormalFixture', 'ApplyFormalInternal', 'RecoverFormalInternal', 'RepairMixedIsolated')]
    [string]$Mode = 'DryRun',

    [string]$StagingRoot,

    [string]$IsolationRoot,

    [string]$TransactionRoot,

    [string]$PreflightObservationPath,

    [ValidateSet('Apply', 'Rollback')]
    [string]$IsolatedAction = 'Apply',

    [ValidateSet('Base', 'OriginallyAbsent', 'ExtraDelete')]
    [string]$MixedFixtureVariant = 'Base',

    [ValidateSet('None', 'Preimage', 'Package', 'Prepare', 'Journal', 'SecondSnapshot', 'EvidenceTamper', 'AdapterBeforeReplace', 'AdapterAfterReplace', 'BackendMarkerAfterReplace', 'PostCheck')]
    [string]$MixedFailureInjection = 'None',

    [ValidateSet('None', 'DirtySource', 'FrontendApply', 'BackendApply', 'Version', 'Smoke', 'Rollback')]
    [string]$FailureInjection = 'None',

    [ValidateSet('None', 'BeforeManagedWrites', 'AfterFirstManagedWriteBeforeRecord', 'AfterFrontendManaged', 'AfterBackendManaged', 'BeforeBackendMarkerWrite', 'AfterBackendMarkerWriteBeforeRecord', 'BeforeFrontendMarkerWrite', 'AfterFrontendMarkerWriteBeforeRecord', 'AfterAllMarkers', 'AbruptAfterFirstManagedWriteBeforeRecord', 'RollbackBeforeFirstRestore', 'RuntimeAfterUpgradeLock', 'RuntimeBeforeFirstWrite', 'RuntimeBeforeMarkers', 'JournalDurabilityBeforeFirstWrite')]
    [string]$FormalApplyFailureInjection = 'None',

    [string]$FrontendTarget = (Join-Path $env:LOCALAPPDATA 'LaplaceSentry'),

    [string]$BackendTarget = '\\wsl.localhost\Ubuntu\home\serpal\.laplace_sentry_backend',

    [string]$BuildVersion
)

<#
.SYNOPSIS
Builds a safe Laplace Sentry upgrade plan or an isolated staging package.

.DESCRIPTION
Purpose: provide the policy-bearing upgrade plan, isolated transaction proofs, formal read-only preflight, prepare evidence, apply eligibility validation, strict-TEMP recovery drills, and a locked internal formal-write capability.
Inputs: repo sources, target paths, mode, staging/isolation/transaction roots, optional fixture observation, isolated action, failure injection, version override.
Outputs: JSON plan/result on stdout; Stage writes package/backup/manifest; isolated modes write fake-target transaction evidence.
SSOT Output: stdout JSON in DryRun/PreflightFormal, upgrade-plan.json in Stage, transaction-journal.json in isolated modes.
Exit codes: 0 success/eligible, 2 preflight/argument failure, 3 isolated staging failure, 4 legacy isolated apply/rollback failure, 5 mixed repair proof failure, 6 formal prepare failure, 7 formal apply eligibility rejection, 8 formal-apply interruption/indeterminate/rollback failure.
Idempotency: read-only modes never write. Stage requires an empty/nonexistent StagingRoot. Isolated modes refuse an existing apply transaction and only permit explicit rollback.
Side effects: Stage and isolated/fixture modes write only inside verified TEMP boundaries. ApplyFormalInternal/RecoverFormalInternal are non-public capabilities locked to fixed formal targets and one pre-existing formal transaction; this work order does not authorize invoking them.
#>

# 這支腳本在做什麼：建立安全升級計畫、只讀檢查正式環境，並用 TEMP 假目標證明 apply／rollback transaction 與中斷恢復。
# 這支腳本不做什麼：不提供公開正式 apply 入口，不啟停真實程序；正式內部模式必須另有明確裁決才可執行。
# 常改區塊：allowlist、Preflight 判定、保留資料清單、隔離 transaction 與 smoke 證明。
# 不要亂動的區塊：Preflight 零寫入邊界、正式目標拒絕、Git blob 來源驗證、Backend/data 保護、journal 驅動 rollback。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$FrontendSource = Join-Path $RepoRoot 'Frontend'
$BackendSource = Join-Path $RepoRoot 'Backend'
$TempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$FormalFrontendTarget = Join-Path $env:LOCALAPPDATA 'LaplaceSentry'
$FormalBackendTarget = '\\wsl.localhost\Ubuntu\home\serpal\.laplace_sentry_backend'
$MixedRepairOriginMain = '1e7bc2b8c3f03d81c79617b0328cfd51f40c0ac1'
$MixedRepairTargetCommit = '971ba498d613c2bb20d46e14855cc0b0a326602a'
$MixedRepairAdapterCommit = '4f228ae5f31754aa43a918274e3b542b6f0a2144'
$MixedRepairMarker = '1e7bc2b'
$MixedRepairSchema = 'laplace-mixed-source-v1'
$MixedRepairAbsentPath = 'Frontend/run_dev_ui.bat'
$MixedRepairExtraPath = 'Frontend/src/mixed-extra-delete.fixture'

$FrontendAllowlist = @(
    'assets',
    'src',
    'requirements.txt',
    'run_ui.bat',
    'run_ui.vbs',
    'run_dev_ui.bat'
)
$FrontendExclude = @('.venv', '__pycache__', '*.pyc', 'laplace_sentry_tray.lock', 'sentry_config.ini', 'version.txt')

$BackendAllowlist = @('main.py', 'requirements.txt', 'src')
$BackendExclude = @('.venv', '__pycache__', '*.pyc', 'cache', 'logs', 'temp', 'data', 'data/projects.json', 'version.txt')

$ProtectedBackupItems = @(
    [pscustomobject]@{ Side = 'Frontend'; RelativePath = 'sentry_config.ini'; Required = $false },
    [pscustomobject]@{ Side = 'Frontend'; RelativePath = 'version.txt'; Required = $false },
    [pscustomobject]@{ Side = 'Backend'; RelativePath = 'data/projects.json'; Required = $true },
    [pscustomobject]@{ Side = 'Backend'; RelativePath = 'version.txt'; Required = $false }
)

$SmokePlan = @(
    'Windows UI single-instance lock and second-launch safe exit',
    'Dashboard opens and project list remains visible',
    'Backend basic command returns successfully',
    'Formal data/projects.json exists and registered projects remain present',
    'Frontend and Backend version markers match the selected build version'
)

$ProcessPlan = @(
    'Windows: pythonw -m src.tray.tray_app under %LOCALAPPDATA%\LaplaceSentry',
    'WSL: daemon/main process under ~/.laplace_sentry_backend',
    'WSL: src/core/sentry_worker.py workers under ~/.laplace_sentry_backend'
)

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Container
    )
    $candidatePath = Get-NormalizedFullPath $Candidate
    $containerPath = Get-NormalizedFullPath $Container
    return $candidatePath.Equals($containerPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidatePath.StartsWith($containerPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-StrictPathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Container
    )
    $candidatePath = Get-NormalizedFullPath $Candidate
    $containerPath = Get-NormalizedFullPath $Container
    return -not $candidatePath.Equals($containerPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        $candidatePath.StartsWith($containerPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PathsOverlap {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )
    return (Test-PathInside -Candidate $First -Container $Second) -or
        (Test-PathInside -Candidate $Second -Container $First)
}

function Assert-NoReparseAmbiguity {
    param([Parameter(Mandatory = $true)][string]$Path)

    $cursor = Get-NormalizedFullPath $Path
    while (-not (Test-Path -LiteralPath $cursor)) {
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    while ($cursor -and (Test-PathInside -Candidate $cursor -Container $TempRoot)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "[UPGRADE_MIXED_BOUNDARY_FAIL] Reparse/junction ambiguity is forbidden: $cursor"
        }
        if (Test-PathsEqual -First $cursor -Second $TempRoot) { break }
        $next = Split-Path -Parent $cursor
        if (-not $next -or $next -eq $cursor) { break }
        $cursor = $next
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-GitOutput {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $priorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $RepoRoot @Arguments 2>$null)
        $gitExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorPreference
    }
    if ($gitExitCode -ne 0) {
        throw "[UPGRADE_GIT_FAIL] git $($Arguments -join ' ') failed."
    }
    return @($output)
}

function Get-HeadCommit {
    return ((Get-GitOutput -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1).Trim())
}

function Get-HeadShortCommit {
    return ((Get-GitOutput -Arguments @('rev-parse', '--short', 'HEAD') | Select-Object -First 1).Trim())
}

function Resolve-BuildVersion {
    if ($BuildVersion) {
        return $BuildVersion
    }
    $gitVersion = (& git -C $RepoRoot rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $gitVersion) {
        return $gitVersion.Trim()
    }
    return [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
}

function Resolve-UpgradeInputs {
    $timestamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $resolvedStage = $StagingRoot
    if (-not $resolvedStage) {
        $resolvedStage = Join-Path ([System.IO.Path]::GetTempPath()) "LaplaceSentryUpgrade\$timestamp"
    }
    return [pscustomobject]@{
        Mode = $Mode
        Timestamp = $timestamp
        BuildVersion = Resolve-BuildVersion
        StagingRoot = Get-NormalizedFullPath $resolvedStage
        FrontendTarget = $FrontendTarget
        BackendTarget = $BackendTarget
        IsolationRoot = if ($IsolationRoot) { Get-NormalizedFullPath $IsolationRoot } else { $null }
        TransactionRoot = if ($TransactionRoot) { Get-NormalizedFullPath $TransactionRoot } else { $null }
        PreflightObservationPath = if ($PreflightObservationPath) { Get-NormalizedFullPath $PreflightObservationPath } else { $null }
    }
}

function Test-PathsEqual {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )
    return (Get-NormalizedFullPath $First).Equals((Get-NormalizedFullPath $Second), [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-FormalPreflightBoundary {
    param([Parameter(Mandatory = $true)]$Inputs)

    $fixtureMode = [bool]($Inputs.IsolationRoot -or $Inputs.PreflightObservationPath)
    if (-not $fixtureMode) {
        if (-not (Test-PathsEqual -First $Inputs.FrontendTarget -Second $FormalFrontendTarget) -or
            -not (Test-PathsEqual -First $Inputs.BackendTarget -Second $FormalBackendTarget)) {
            throw '[UPGRADE_PREFLIGHT_FAIL] Live PreflightFormal only accepts the fixed formal targets.'
        }
        return
    }

    if (-not $Inputs.IsolationRoot -or -not $Inputs.PreflightObservationPath) {
        throw '[UPGRADE_PREFLIGHT_FAIL] Fixture PreflightFormal requires both IsolationRoot and PreflightObservationPath.'
    }
    if (-not (Test-StrictPathInside -Candidate $Inputs.IsolationRoot -Container $TempRoot)) {
        throw '[UPGRADE_PREFLIGHT_FAIL] Fixture IsolationRoot must be a strict child of the system TEMP root.'
    }
    foreach ($candidate in @($Inputs.FrontendTarget, $Inputs.BackendTarget, $Inputs.PreflightObservationPath)) {
        if (-not (Test-StrictPathInside -Candidate $candidate -Container $Inputs.IsolationRoot)) {
            throw "[UPGRADE_PREFLIGHT_FAIL] Fixture path escaped IsolationRoot: $candidate"
        }
        if (Test-PathInside -Candidate $candidate -Container $RepoRoot) {
            throw "[UPGRADE_PREFLIGHT_FAIL] Repository paths are forbidden fixture targets: $candidate"
        }
        if ((Test-PathInside -Candidate $candidate -Container $FormalFrontendTarget) -or
            (Test-PathInside -Candidate $candidate -Container $FormalBackendTarget)) {
            throw "[UPGRADE_PREFLIGHT_FAIL] Formal runtime paths are forbidden fixture targets: $candidate"
        }
    }
    foreach ($pair in @(
        [pscustomobject]@{ First = $Inputs.FrontendTarget; Second = $Inputs.BackendTarget; Label = 'FrontendTarget and BackendTarget' },
        [pscustomobject]@{ First = $Inputs.FrontendTarget; Second = $Inputs.PreflightObservationPath; Label = 'FrontendTarget and observation' },
        [pscustomobject]@{ First = $Inputs.BackendTarget; Second = $Inputs.PreflightObservationPath; Label = 'BackendTarget and observation' }
    )) {
        if (Test-PathsOverlap -First $pair.First -Second $pair.Second) {
            throw "[UPGRADE_PREFLIGHT_FAIL] Fixture $($pair.Label) must be mutually exclusive."
        }
    }
    if (-not (Test-Path -LiteralPath $Inputs.PreflightObservationPath -PathType Leaf)) {
        throw '[UPGRADE_PREFLIGHT_FAIL] Fixture observation JSON is missing.'
    }
}

function Assert-IsolatedBoundary {
    param([Parameter(Mandatory = $true)]$Inputs)

    if (-not $Inputs.IsolationRoot) {
        throw '[UPGRADE_ISOLATED_PREFLIGHT_FAIL] IsolationRoot is required.'
    }
    if (-not (Test-StrictPathInside -Candidate $Inputs.IsolationRoot -Container $TempRoot)) {
        throw '[UPGRADE_ISOLATED_PREFLIGHT_FAIL] IsolationRoot must be a strict child of the system TEMP root.'
    }
    foreach ($candidate in @($Inputs.StagingRoot, $Inputs.FrontendTarget, $Inputs.BackendTarget)) {
        if (-not (Test-StrictPathInside -Candidate $candidate -Container $Inputs.IsolationRoot)) {
            throw "[UPGRADE_ISOLATED_PREFLIGHT_FAIL] Every staging/target path must be a strict child of IsolationRoot: $candidate"
        }
        if (Test-PathInside -Candidate $candidate -Container $RepoRoot) {
            throw "[UPGRADE_ISOLATED_PREFLIGHT_FAIL] Repository paths are forbidden targets: $candidate"
        }
        if ((Test-PathInside -Candidate $candidate -Container $FormalFrontendTarget) -or
            (Test-PathInside -Candidate $candidate -Container $FormalBackendTarget)) {
            throw "[UPGRADE_ISOLATED_PREFLIGHT_FAIL] Formal runtime paths are forbidden: $candidate"
        }
    }
    if ($Inputs.BackendTarget -match '(?i)(^|[\\/])\.laplace_sentry_backend([\\/]|$)') {
        throw '[UPGRADE_ISOLATED_PREFLIGHT_FAIL] A real backend runtime-shaped target is forbidden.'
    }
    $pathPairs = @(
        [pscustomobject]@{ First = $Inputs.StagingRoot; Second = $Inputs.FrontendTarget; Label = 'StagingRoot and FrontendTarget' },
        [pscustomobject]@{ First = $Inputs.StagingRoot; Second = $Inputs.BackendTarget; Label = 'StagingRoot and BackendTarget' },
        [pscustomobject]@{ First = $Inputs.FrontendTarget; Second = $Inputs.BackendTarget; Label = 'FrontendTarget and BackendTarget' }
    )
    foreach ($pair in $pathPairs) {
        if (Test-PathsOverlap -First $pair.First -Second $pair.Second) {
            throw "[UPGRADE_ISOLATED_PREFLIGHT_FAIL] $($pair.Label) must be mutually exclusive trees."
        }
    }
}

function Assert-MixedRepairBoundary {
    param([Parameter(Mandatory = $true)]$Inputs)

    if (-not $IsolationRoot -or -not $StagingRoot -or -not $TransactionRoot -or -not $PreflightObservationPath) {
        throw '[UPGRADE_MIXED_BOUNDARY_FAIL] RepairMixedIsolated requires explicit IsolationRoot, StagingRoot, TransactionRoot, and PreflightObservationPath.'
    }
    if (-not (Test-StrictPathInside -Candidate $Inputs.IsolationRoot -Container $TempRoot)) {
        throw '[UPGRADE_MIXED_BOUNDARY_FAIL] IsolationRoot must be a strict child of system TEMP.'
    }
    if (-not (Test-Path -LiteralPath $Inputs.IsolationRoot -PathType Container)) {
        throw '[UPGRADE_MIXED_BOUNDARY_FAIL] IsolationRoot must already exist; the repair proof never creates its own outer boundary.'
    }

    $peers = @(
        [pscustomobject]@{ Label = 'StagingRoot'; Path = $Inputs.StagingRoot },
        [pscustomobject]@{ Label = 'TransactionRoot'; Path = $Inputs.TransactionRoot },
        [pscustomobject]@{ Label = 'FrontendTarget'; Path = $Inputs.FrontendTarget },
        [pscustomobject]@{ Label = 'BackendTarget'; Path = $Inputs.BackendTarget },
        [pscustomobject]@{ Label = 'PreflightObservationPath'; Path = $Inputs.PreflightObservationPath }
    )
    foreach ($peer in $peers) {
        if (-not (Test-StrictPathInside -Candidate $peer.Path -Container $Inputs.IsolationRoot)) {
            throw "[UPGRADE_MIXED_BOUNDARY_FAIL] $($peer.Label) escaped IsolationRoot: $($peer.Path)"
        }
        foreach ($forbidden in @($RepoRoot, $FormalFrontendTarget, $FormalBackendTarget)) {
            if (Test-PathsOverlap -First $peer.Path -Second $forbidden) {
                throw "[UPGRADE_MIXED_BOUNDARY_FAIL] $($peer.Label) overlaps a repository or formal runtime path: $($peer.Path)"
            }
        }
        Assert-NoReparseAmbiguity -Path $peer.Path
    }
    for ($first = 0; $first -lt $peers.Count; $first++) {
        for ($second = $first + 1; $second -lt $peers.Count; $second++) {
            if (Test-PathsOverlap -First $peers[$first].Path -Second $peers[$second].Path) {
                throw "[UPGRADE_MIXED_BOUNDARY_FAIL] $($peers[$first].Label) and $($peers[$second].Label) must be mutually exclusive trees."
            }
        }
    }
    if ($Inputs.BackendTarget -match '(?i)(^|[\\/])\.laplace_sentry_backend([\\/]|$)') {
        throw '[UPGRADE_MIXED_BOUNDARY_FAIL] A real backend runtime-shaped target is forbidden.'
    }
    foreach ($required in @($Inputs.FrontendTarget, $Inputs.BackendTarget)) {
        if (-not (Test-Path -LiteralPath $required -PathType Container)) {
            throw "[UPGRADE_MIXED_BOUNDARY_FAIL] Fake target is missing: $required"
        }
    }
    if (-not (Test-Path -LiteralPath $Inputs.PreflightObservationPath -PathType Leaf)) {
        throw '[UPGRADE_MIXED_BOUNDARY_FAIL] Fixture process/registry observation JSON is missing.'
    }
    foreach ($root in @($Inputs.StagingRoot, $Inputs.TransactionRoot)) {
        if ($IsolatedAction -eq 'Apply' -and (Test-Path -LiteralPath $root)) {
            if (@(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop).Count -gt 0) {
                throw "[UPGRADE_MIXED_BOUNDARY_FAIL] Apply requires an empty or nonexistent evidence root: $root"
            }
        }
    }
}

function Assert-UpgradePreflight {
    param([Parameter(Mandatory = $true)]$Inputs)

    foreach ($requiredPath in @($FrontendSource, $BackendSource)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Container)) {
            throw "[UPGRADE_PREFLIGHT_FAIL] Missing source directory: $requiredPath"
        }
    }

    if ($Inputs.Mode -eq 'ApplyIsolated') {
        Assert-IsolatedBoundary -Inputs $Inputs
        return
    }

    if ($Inputs.Mode -eq 'RepairMixedIsolated') {
        Assert-MixedRepairBoundary -Inputs $Inputs
        return
    }

    if ($Inputs.Mode -eq 'PreflightFormal') {
        Assert-FormalPreflightBoundary -Inputs $Inputs
        return
    }

    if ($Inputs.Mode -eq 'PrepareFormal') {
        Assert-FormalPrepareBoundary -Inputs $Inputs
        return
    }

    if ($Inputs.Mode -eq 'ValidateFormalApply') {
        Assert-FormalApplyValidationBoundary -Inputs $Inputs
        return
    }

    if ($Inputs.Mode -in @('ApplyFormalFixture', 'RecoverFormalFixture', 'ApplyFormalInternal', 'RecoverFormalInternal')) {
        Assert-FormalApplyExecutionBoundary -Inputs $Inputs
        return
    }

    if (Test-PathInside -Candidate $Inputs.StagingRoot -Container $RepoRoot) {
        throw '[UPGRADE_PREFLIGHT_FAIL] StagingRoot must be outside the repository.'
    }
    if (Test-PathInside -Candidate $Inputs.StagingRoot -Container $Inputs.FrontendTarget) {
        throw '[UPGRADE_PREFLIGHT_FAIL] StagingRoot must not be inside the formal Frontend target.'
    }
    if (Test-PathInside -Candidate $Inputs.StagingRoot -Container $Inputs.BackendTarget) {
        throw '[UPGRADE_PREFLIGHT_FAIL] StagingRoot must not be inside the formal Backend target.'
    }

    if ($Inputs.Mode -eq 'Stage' -and (Test-Path -LiteralPath $Inputs.StagingRoot)) {
        $existing = @(Get-ChildItem -LiteralPath $Inputs.StagingRoot -Force -ErrorAction Stop)
        if ($existing.Count -gt 0) {
            throw '[UPGRADE_PREFLIGHT_FAIL] Stage mode requires an empty or nonexistent StagingRoot.'
        }
    }
}

function Get-AllowedSourceFiles {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string[]]$Allowlist
    )

    $files = foreach ($entry in $Allowlist) {
        $path = Join-Path $SourceRoot $entry
        if (-not (Test-Path -LiteralPath $path)) {
            throw "[UPGRADE_PREFLIGHT_FAIL] Allowlisted source is missing: $path"
        }
        if (Test-Path -LiteralPath $path -PathType Container) {
            Get-ChildItem -LiteralPath $path -Recurse -File | Where-Object {
                $_.FullName -notmatch '([\\/])(__pycache__|\.venv)([\\/])' -and $_.Extension -ne '.pyc'
            }
        }
        else {
            Get-Item -LiteralPath $path
        }
    }

    return @($files | Sort-Object FullName -Unique | ForEach-Object {
        [pscustomobject]@{
            FullName = $_.FullName
            RelativePath = $_.FullName.Substring($SourceRoot.Length + 1)
            Length = $_.Length
        }
    })
}

function New-UpgradePlan {
    param([Parameter(Mandatory = $true)]$Inputs)

    $frontendFiles = Get-AllowedSourceFiles -SourceRoot $FrontendSource -Allowlist $FrontendAllowlist
    $backendFiles = Get-AllowedSourceFiles -SourceRoot $BackendSource -Allowlist $BackendAllowlist

    if ($backendFiles.RelativePath -contains 'data\projects.json') {
        throw '[UPGRADE_POLICY_FAIL] Backend data/projects.json entered the package plan.'
    }

    return [ordered]@{
        schema_version = 1
        mode = $Inputs.Mode
        safety = 'formal-targets-read-only'
        build_version = $Inputs.BuildVersion
        timestamp = $Inputs.Timestamp
        sources = [ordered]@{ frontend = $FrontendSource; backend = $BackendSource }
        formal_targets = [ordered]@{ frontend = $Inputs.FrontendTarget; backend = $Inputs.BackendTarget }
        staging = [ordered]@{
            root = $Inputs.StagingRoot
            package = (Join-Path $Inputs.StagingRoot 'package')
            backup = (Join-Path $Inputs.StagingRoot 'backup')
            rollback_plan = (Join-Path $Inputs.StagingRoot 'rollback-plan.json')
        }
        allowlist = [ordered]@{ frontend = $FrontendAllowlist; backend = $BackendAllowlist }
        exclude = [ordered]@{ frontend = $FrontendExclude; backend = $BackendExclude }
        protected_data = @('Frontend/sentry_config.ini', 'Backend/data/projects.json', 'formal version.txt markers')
        planned_process_preflight = $ProcessPlan
        planned_backup_items = $ProtectedBackupItems
        smoke_plan = $SmokePlan
        rollback = 'Restore managed files and version markers from the same timestamped backup; never restore repo Backend/data/projects.json over formal data.'
        files = [ordered]@{ frontend = $frontendFiles; backend = $backendFiles }
    }
}

function Copy-FilePreservingRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )
    $destination = Join-Path $DestinationRoot $RelativePath
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $destination -Force
}

function Backup-ProtectedItemsToStaging {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )
    $records = @()
    foreach ($item in $ProtectedBackupItems) {
        $targetRoot = if ($item.Side -eq 'Frontend') { $Inputs.FrontendTarget } else { $Inputs.BackendTarget }
        $source = Join-Path $targetRoot $item.RelativePath
        $relativeBackup = Join-Path $item.Side $item.RelativePath
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-FilePreservingRelativePath -SourcePath $source -RelativePath $relativeBackup -DestinationRoot $BackupRoot
            $records += [pscustomobject]@{
                side = $item.Side
                relative_path = $item.RelativePath
                backup_path = (Join-Path $BackupRoot $relativeBackup)
                restore_target = $source
                sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
            }
        }
        elseif ($item.Required) {
            throw "[UPGRADE_BACKUP_FAIL] Required protected data is missing: $source"
        }
    }
    return $records
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Payload
    )
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $tempPath = "$Path.tmp"
    $Payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Invoke-IsolatedStage {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Plan
    )
    $packageRoot = $Plan.staging.package
    $backupRoot = $Plan.staging.backup
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

    foreach ($file in $Plan.files.frontend) {
        Copy-FilePreservingRelativePath -SourcePath $file.FullName -RelativePath $file.RelativePath -DestinationRoot (Join-Path $packageRoot 'Frontend')
    }
    foreach ($file in $Plan.files.backend) {
        Copy-FilePreservingRelativePath -SourcePath $file.FullName -RelativePath $file.RelativePath -DestinationRoot (Join-Path $packageRoot 'Backend')
    }

    $backupRecords = Backup-ProtectedItemsToStaging -Inputs $Inputs -BackupRoot $backupRoot
    $rollbackPlan = [ordered]@{
        schema_version = 1
        build_version = $Inputs.BuildVersion
        formal_apply_supported = $false
        records = $backupRecords
        instructions = @(
            'A later authorized apply flow must stop exact owned processes before restore.',
            'Restore every record to restore_target from the same timestamped backup.',
            'Verify SHA-256 after restore, then run the declared smoke plan.'
        )
    }
    Write-JsonAtomic -Path $Plan.staging.rollback_plan -Payload $rollbackPlan

    $manifest = [ordered]@{}
    foreach ($key in $Plan.Keys) { $manifest[$key] = $Plan[$key] }
    $manifest['backup_records'] = $backupRecords
    $manifest['stage_result'] = 'isolated-package-created'
    Write-JsonAtomic -Path (Join-Path $Inputs.StagingRoot 'upgrade-plan.json') -Payload $manifest
}

function Assert-ManagedSourcesMatchHead {
    param([Parameter(Mandatory = $true)]$Plan)

    foreach ($side in @('frontend', 'backend')) {
        $prefix = if ($side -eq 'frontend') { 'Frontend' } else { 'Backend' }
        foreach ($file in $Plan.files[$side]) {
            $gitPath = ($prefix + '/' + $file.RelativePath.Replace('\', '/'))
            [void](Get-GitOutput -Arguments @('ls-files', '--error-unmatch', '--', $gitPath))
            $headBlob = (Get-GitOutput -Arguments @('rev-parse', "HEAD:$gitPath") | Select-Object -First 1).Trim()
            $workingBlob = (Get-GitOutput -Arguments @('hash-object', '--', $file.FullName) | Select-Object -First 1).Trim()
            if (-not $headBlob.Equals($workingBlob, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "[UPGRADE_SOURCE_DIRTY] Managed source differs from HEAD: $gitPath"
            }
        }
    }

    $workingDeletions = @(Get-GitOutput -Arguments @('diff', '--name-only', '--diff-filter=D', 'HEAD', '--', 'Frontend', 'Backend'))
    if ($workingDeletions.Count -gt 0) {
        throw "[UPGRADE_SOURCE_DELETE] Working tree contains tracked deletion(s): $($workingDeletions -join ', ')"
    }
    if ($FailureInjection -eq 'DirtySource') {
        throw '[UPGRADE_SOURCE_DIRTY] Injected dirty managed source rejection.'
    }
}

function Resolve-IsolatedVersionContract {
    param([Parameter(Mandatory = $true)]$Inputs)

    $frontendVersionPath = Join-Path $Inputs.FrontendTarget 'version.txt'
    $backendVersionPath = Join-Path $Inputs.BackendTarget 'version.txt'
    foreach ($path in @($frontendVersionPath, $backendVersionPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "[UPGRADE_VERSION_FAIL] Isolated target version marker is missing: $path"
        }
    }
    $frontendOld = (Get-Content -LiteralPath $frontendVersionPath -Raw).Trim()
    $backendOld = (Get-Content -LiteralPath $backendVersionPath -Raw).Trim()
    if (-not $frontendOld -or -not $frontendOld.Equals($backendOld, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '[UPGRADE_VERSION_FAIL] Frontend and Backend old version markers must match.'
    }

    $oldCommit = (Get-GitOutput -Arguments @('rev-parse', "$frontendOld^{commit}") | Select-Object -First 1).Trim()
    $headCommit = Get-HeadCommit
    $headShort = Get-HeadShortCommit
    $priorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $RepoRoot merge-base --is-ancestor $oldCommit $headCommit 2>$null
        $isAncestor = ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $priorPreference
    }
    if (-not $isAncestor) {
        throw '[UPGRADE_VERSION_FAIL] Old version must be an ancestor of the current HEAD.'
    }
    if ($BuildVersion -and -not $BuildVersion.Equals($headShort, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '[UPGRADE_VERSION_FAIL] ApplyIsolated BuildVersion must equal the current HEAD short commit.'
    }

    $deletions = @(Get-GitOutput -Arguments @('diff', '--name-only', '--diff-filter=D', "$oldCommit..$headCommit", '--', 'Frontend', 'Backend'))
    if ($deletions.Count -gt 0) {
        throw "[UPGRADE_POLICY_FAIL] No-delete overlay rejects tracked deletion(s): $($deletions -join ', ')"
    }
    $requirements = @(Get-GitOutput -Arguments @('diff', '--name-only', "$oldCommit..$headCommit", '--', 'Frontend/requirements.txt', 'Backend/requirements.txt'))
    if ($requirements.Count -gt 0) {
        throw "[UPGRADE_POLICY_FAIL] Requirements changes require a separately ruled migration: $($requirements -join ', ')"
    }
    return [pscustomobject]@{
        OldVersion = $frontendOld
        OldCommit = $oldCommit
        HeadCommit = $headCommit
        NewVersion = $headShort
        FrontendPath = $frontendVersionPath
        BackendPath = $backendVersionPath
    }
}

# =========================
# 正式只讀 Preflight
# =========================

function New-FormalPreflightResult {
    param([Parameter(Mandatory = $true)]$Inputs)
    return [pscustomobject]@{
        schema_version = 1
        mode = 'PreflightFormal'
        result = 'indeterminate'
        safe_to_upgrade = $false
        head_commit = $null
        target_version = $null
        checks = @()
        failures = @()
        warnings = @()
        targets = [pscustomobject]@{
            frontend = [pscustomobject]@{ path = $Inputs.FrontendTarget; exists = $false }
            backend = [pscustomobject]@{ path = $Inputs.BackendTarget; exists = $false }
        }
        processes = [pscustomobject]@{
            ui = @()
            daemon = @()
            workers = @()
            stale_registry = @()
            ambiguous_runtime = @()
        }
        fingerprints = @()
        excluded = [pscustomobject]@{ paper_watcher = $true }
    }
}

function Add-FormalPreflightCheck {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$TruthSource,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    $Result.checks += [pscustomobject]@{ id = $Id; status = $Status; truth_source = $TruthSource; reason = $Reason }
}

function Add-FormalPreflightFailure {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$CheckId,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $Result.failures += [pscustomobject]@{ tag = $Tag; check_id = $CheckId; message = $Message }
}

function Add-FormalPreflightWarning {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$CheckId,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $Result.warnings += [pscustomobject]@{ tag = $Tag; check_id = $CheckId; message = $Message }
}

function Get-OptionalProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default
    )
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-ReadonlyFileFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ label = $Label; path = $Path; exists = $false; length = $null; sha256 = $null; last_write_utc = $null }
    }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return [pscustomobject]@{
        label = $Label
        path = $Path
        exists = $true
        length = $item.Length
        sha256 = Get-FileSha256 $Path
        last_write_utc = $item.LastWriteTimeUtc.ToString('o')
    }
}

function Get-ManagedTargetFiles {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$GitPrefix,
        [Parameter(Mandatory = $true)][string[]]$Allowlist
    )
    $files = @()
    foreach ($entry in $Allowlist) {
        $path = Join-Path $TargetRoot $entry
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $files += Get-Item -LiteralPath $path
        }
        elseif (Test-Path -LiteralPath $path -PathType Container) {
            $files += Get-ChildItem -LiteralPath $path -Recurse -File | Where-Object {
                $_.FullName -notmatch '([\/])(__pycache__|\.venv)([\/])' -and $_.Extension -ne '.pyc'
            }
        }
    }
    return @($files | Sort-Object FullName -Unique | ForEach-Object {
        $relative = $_.FullName.Substring($TargetRoot.Length + 1).Replace('\', '/')
        [pscustomobject]@{ git_path = "$GitPrefix/$relative"; full_name = $_.FullName }
    })
}

function Get-ExpectedManagedGitPaths {
    param([Parameter(Mandatory = $true)][string]$Commit)
    $pathSpecs = @()
    $pathSpecs += @($FrontendAllowlist | ForEach-Object { 'Frontend/' + $_.Replace('\', '/') })
    $pathSpecs += @($BackendAllowlist | ForEach-Object { 'Backend/' + $_.Replace('\', '/') })
    $paths = @(Get-GitOutput -Arguments (@('ls-tree', '-r', '--name-only', $Commit, '--') + $pathSpecs))
    return @($paths | Where-Object {
        $_ -and $_ -notmatch '(^|/)(__pycache__|\.venv)(/|$)' -and $_ -notmatch '\.pyc$'
    } | Sort-Object -Unique)
}

function Get-FormalTargetCoherence {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)][string]$MarkerCommit
    )
    $actual = @()
    $actual += Get-ManagedTargetFiles -TargetRoot $Inputs.FrontendTarget -GitPrefix 'Frontend' -Allowlist $FrontendAllowlist
    $actual += Get-ManagedTargetFiles -TargetRoot $Inputs.BackendTarget -GitPrefix 'Backend' -Allowlist $BackendAllowlist
    $expectedPaths = @(Get-ExpectedManagedGitPaths -Commit $MarkerCommit)
    $actualByPath = @{}
    foreach ($record in $actual) { $actualByPath[$record.git_path] = $record.full_name }

    $missing = @($expectedPaths | Where-Object { -not $actualByPath.ContainsKey($_) })
    $extra = @($actualByPath.Keys | Where-Object { $_ -notin $expectedPaths } | Sort-Object)
    $blobDrift = @()
    foreach ($gitPath in $expectedPaths) {
        if (-not $actualByPath.ContainsKey($gitPath)) { continue }
        $expectedBlob = (Get-GitOutput -Arguments @('rev-parse', "$MarkerCommit`:$gitPath") | Select-Object -First 1).Trim()
        $actualBlob = (Get-GitOutput -Arguments @('hash-object', '--', $actualByPath[$gitPath]) | Select-Object -First 1).Trim()
        if (-not $expectedBlob.Equals($actualBlob, [System.StringComparison]::OrdinalIgnoreCase)) {
            $blobDrift += [pscustomobject]@{ path = $gitPath; expected_blob = $expectedBlob; actual_blob = $actualBlob }
        }
    }
    return [pscustomobject]@{ expected_count = $expectedPaths.Count; actual_count = $actual.Count; missing = $missing; extra = $extra; blob_drift = $blobDrift }
}

function Read-PreflightFixtureObservation {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
}

function Get-WslProcessRecord {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $priorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & wsl.exe -d Ubuntu -- test -d "/proc/$ProcessId" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $exe = (@(& wsl.exe -d Ubuntu -- readlink "/proc/$ProcessId/exe" 2>$null) | Select-Object -First 1)
        $cwd = (@(& wsl.exe -d Ubuntu -- readlink "/proc/$ProcessId/cwd" 2>$null) | Select-Object -First 1)
        $cmd = (@(& wsl.exe -d Ubuntu -- sh -lc "tr '\0' ' ' < /proc/$ProcessId/cmdline" 2>$null) | Select-Object -First 1)
    }
    finally {
        $ErrorActionPreference = $priorPreference
    }
    return [pscustomobject]@{ pid = $ProcessId; executable = [string]$exe; cwd = [string]$cwd; cmdline = ([string]$cmd).Trim() }
}

function Get-LivePreflightObservation {
    param([Parameter(Mandatory = $true)]$Inputs)
    $formalFrontendPython = Join-Path $FormalFrontendTarget '.venv\Scripts\pythonw.exe'
    $ui = @()
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        $exeMatch = $process.ExecutablePath -and $process.ExecutablePath.Equals($formalFrontendPython, [System.StringComparison]::OrdinalIgnoreCase)
        $cmdMatch = $process.CommandLine -and $process.CommandLine -match '(?i)(^|\s)-m\s+src\.tray\.tray_app(\s|$)'
        if ($exeMatch -or $cmdMatch) {
            $ui += [pscustomobject]@{
                pid = [int]$process.ProcessId
                executable = $process.ExecutablePath
                cmdline = $process.CommandLine
                owned = [bool]($exeMatch -and $cmdMatch)
                ambiguous = [bool](-not ($exeMatch -and $cmdMatch))
            }
        }
    }

    $formalWslRoot = '/home/serpal/.laplace_sentry_backend'
    $expectedWslPython = "$formalWslRoot/.venv/bin/python"
    $priorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $expectedWslExe = (@(& wsl.exe -d Ubuntu -- readlink -f $expectedWslPython 2>$null) | Select-Object -First 1)
        $psLines = @(& wsl.exe -d Ubuntu -- ps -eo pid=,args= 2>$null)
        $psExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorPreference
    }
    if ($psExit -ne 0) { throw '[UPGRADE_PREFLIGHT_FAIL] Unable to read WSL process table.' }

    $daemon = @()
    $workers = @()
    foreach ($line in $psLines) {
        if ($line -notmatch '^\s*(\d+)\s+(.+)$') { continue }
        $processId = [int]$Matches[1]
        $args = $Matches[2]
        if ($args -notmatch '(?i)\.laplace_sentry_backend') { continue }
        $record = Get-WslProcessRecord -ProcessId $processId
        if ($null -eq $record) { continue }
        $exeMatch = $expectedWslExe -and $record.executable -eq $expectedWslExe
        $cwdMatch = $record.cwd -eq $formalWslRoot
        $pythonArgvMatch = $record.cmdline.StartsWith($expectedWslPython + ' ', [System.StringComparison]::Ordinal)
        if ($record.cmdline -match '(^|\s)-m\s+src\.core\.daemon(\s|$)') {
            $owned = [bool]($exeMatch -and $cwdMatch -and $pythonArgvMatch)
            $daemon += [pscustomobject]@{ pid = $processId; executable = $record.executable; cwd = $record.cwd; cmdline = $record.cmdline; owned = $owned; ambiguous = (-not $owned) }
        }
        elseif ($record.cmdline -match [regex]::Escape("$formalWslRoot/src/core/sentry_worker.py")) {
            $owned = [bool]($exeMatch -and $cwdMatch -and $pythonArgvMatch)
            $workers += [pscustomobject]@{ pid = $processId; executable = $record.executable; cwd = $record.cwd; cmdline = $record.cmdline; owned = $owned; ambiguous = (-not $owned); registered = $false; uuid = $null }
        }
        else {
            $daemon += [pscustomobject]@{ pid = $processId; executable = $record.executable; cwd = $record.cwd; cmdline = $record.cmdline; owned = $false; ambiguous = $true }
        }
    }

    $registry = @()
    $registryDir = Join-Path $FormalBackendTarget 'temp\sentry'
    if (Test-Path -LiteralPath $registryDir -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $registryDir -File -Filter '*.sentry' -ErrorAction Stop | Sort-Object Name)) {
            $fingerprint = Get-ReadonlyFileFingerprint -Path $file.FullName -Label "registry/$($file.Name)"
            if ($file.BaseName -notmatch '^\d+$') {
                $registry += [pscustomobject]@{ pid = $null; uuid = (Get-Content -LiteralPath $file.FullName -Raw).Trim(); path = $file.FullName; proc_exists = $false; owned = $false; uuid_matches = $false; ambiguous = $true; fingerprint = $fingerprint }
                continue
            }
            $processId = [int]$file.BaseName
            $uuid = (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
            $proc = Get-WslProcessRecord -ProcessId $processId
            $worker = @($workers | Where-Object { $_.pid -eq $processId } | Select-Object -First 1)
            $procExists = $null -ne $proc
            $workerMatch = $worker.Count -eq 1
            $uuidMatches = $workerMatch -and $worker[0].cmdline -match ('(^|\s)' + [regex]::Escape($uuid) + '(\s|$)')
            $owned = $workerMatch -and $worker[0].owned -and $uuidMatches
            $ambiguous = $procExists -and -not $owned
            if ($workerMatch) { $worker[0].registered = $owned; $worker[0].uuid = $uuid }
            $registry += [pscustomobject]@{ pid = $processId; uuid = $uuid; path = $file.FullName; proc_exists = $procExists; owned = $owned; uuid_matches = $uuidMatches; ambiguous = $ambiguous; fingerprint = $fingerprint }
        }
    }

    foreach ($worker in $workers) {
        if (-not $worker.registered) { $worker.ambiguous = $true }
    }
    return [pscustomobject]@{
        source_dirty = $false
        tracked_deletions = @()
        requirements_changes = @()
        force_non_ancestor = $false
        protected_unreadable = @()
        lock_exists = (Test-Path -LiteralPath (Join-Path $FormalFrontendTarget 'laplace_sentry_tray.lock') -PathType Leaf)
        ui = $ui
        daemon = $daemon
        workers = $workers
        registry = $registry
    }
}

function Apply-PreflightProcessAssessment {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$Observation
    )
    $ui = @(Get-OptionalProperty -Object $Observation -Name 'ui' -Default @())
    $daemon = @(Get-OptionalProperty -Object $Observation -Name 'daemon' -Default @())
    $workers = @(Get-OptionalProperty -Object $Observation -Name 'workers' -Default @())
    $registry = @(Get-OptionalProperty -Object $Observation -Name 'registry' -Default @())
    $Result.processes.ui = $ui
    $Result.processes.daemon = $daemon
    $Result.processes.workers = $workers

    if ([bool](Get-OptionalProperty -Object $Observation -Name 'lock_exists' -Default $false)) {
        Add-FormalPreflightFailure -Result $Result -Tag '[UPGRADE_UI_ACTIVE]' -CheckId 'runtime' -Message 'The formal UI QLockFile exists.'
    }
    foreach ($record in $ui) {
        if ([bool](Get-OptionalProperty -Object $record -Name 'ambiguous' -Default $false)) {
            $Result.processes.ambiguous_runtime += $record
        }
        elseif ([bool](Get-OptionalProperty -Object $record -Name 'owned' -Default $false)) {
            Add-FormalPreflightFailure -Result $Result -Tag '[UPGRADE_UI_ACTIVE]' -CheckId 'runtime' -Message "Owned formal UI process is active: PID $($record.pid)."
        }
    }
    foreach ($record in $daemon) {
        if ([bool](Get-OptionalProperty -Object $record -Name 'ambiguous' -Default $false)) {
            $Result.processes.ambiguous_runtime += $record
        }
        elseif ([bool](Get-OptionalProperty -Object $record -Name 'owned' -Default $false)) {
            Add-FormalPreflightFailure -Result $Result -Tag '[UPGRADE_RUNTIME_ACTIVE]' -CheckId 'runtime' -Message "Owned formal daemon is active: PID $($record.pid)."
        }
    }
    foreach ($record in $workers) {
        $registered = [bool](Get-OptionalProperty -Object $record -Name 'registered' -Default $false)
        $ambiguous = [bool](Get-OptionalProperty -Object $record -Name 'ambiguous' -Default $false)
        if ($ambiguous -or -not $registered) {
            $Result.processes.ambiguous_runtime += $record
        }
        elseif ([bool](Get-OptionalProperty -Object $record -Name 'owned' -Default $false)) {
            Add-FormalPreflightFailure -Result $Result -Tag '[UPGRADE_RUNTIME_ACTIVE]' -CheckId 'runtime' -Message "Owned formal worker is active: PID $($record.pid)."
        }
    }
    foreach ($record in $registry) {
        if (-not [bool](Get-OptionalProperty -Object $record -Name 'proc_exists' -Default $false) -and
            -not [bool](Get-OptionalProperty -Object $record -Name 'ambiguous' -Default $false)) {
            $Result.processes.stale_registry += $record
            Add-FormalPreflightWarning -Result $Result -Tag '[UPGRADE_REGISTRY_STALE]' -CheckId 'runtime' -Message "Stale registry is preserved: PID $($record.pid)."
        }
        elseif ([bool](Get-OptionalProperty -Object $record -Name 'ambiguous' -Default $false) -or
            -not [bool](Get-OptionalProperty -Object $record -Name 'owned' -Default $false) -or
            -not [bool](Get-OptionalProperty -Object $record -Name 'uuid_matches' -Default $false)) {
            $Result.processes.ambiguous_runtime += $record
        }
    }
    if ($Result.processes.ambiguous_runtime.Count -gt 0) {
        Add-FormalPreflightFailure -Result $Result -Tag '[UPGRADE_RUNTIME_AMBIGUOUS]' -CheckId 'runtime' -Message 'Runtime ownership could not be proven for one or more process/registry records.'
    }
    $runtimeStatus = if (@($Result.failures | Where-Object { $_.check_id -eq 'runtime' }).Count -gt 0) { 'fail' } else { 'pass' }
    Add-FormalPreflightCheck -Result $Result -Id 'runtime' -Status $runtimeStatus -TruthSource 'Win32 CIM, QLockFile, WSL /proc and literal temp/sentry registry' -Reason "ui=$($ui.Count), daemon=$($daemon.Count), workers=$($workers.Count), stale=$($Result.processes.stale_registry.Count), ambiguous=$($Result.processes.ambiguous_runtime.Count)"
}

function Invoke-FormalPreflightMode {
    param([Parameter(Mandatory = $true)]$Inputs)
    $result = New-FormalPreflightResult -Inputs $Inputs
    $fixtureMode = [bool]$Inputs.PreflightObservationPath
    $observation = if ($fixtureMode) { Read-PreflightFixtureObservation -Path $Inputs.PreflightObservationPath } else { Get-LivePreflightObservation -Inputs $Inputs }
    $result.head_commit = Get-HeadCommit

    $plan = $null
    try {
        $plan = New-UpgradePlan -Inputs $Inputs
        Assert-ManagedSourcesMatchHead -Plan $plan
        if ([bool](Get-OptionalProperty -Object $observation -Name 'source_dirty' -Default $false)) {
            throw '[UPGRADE_SOURCE_DIRTY] Fixture source dirty rejection.'
        }
        Add-FormalPreflightCheck -Result $result -Id 'source' -Status 'pass' -TruthSource 'Git HEAD blobs and working file hash-object' -Reason 'All managed source files equal HEAD.'
    }
    catch {
        Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_SOURCE_DIRTY]' -CheckId 'source' -Message $_.Exception.Message
        Add-FormalPreflightCheck -Result $result -Id 'source' -Status 'fail' -TruthSource 'Git HEAD blobs and working file hash-object' -Reason $_.Exception.Message
    }

    $frontendExists = Test-Path -LiteralPath $Inputs.FrontendTarget -PathType Container
    $backendExists = Test-Path -LiteralPath $Inputs.BackendTarget -PathType Container
    $result.targets.frontend.exists = $frontendExists
    $result.targets.backend.exists = $backendExists
    if (-not $frontendExists -or -not $backendExists) {
        Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_TARGET_FAIL]' -CheckId 'target_version' -Message 'One or both formal targets are missing.'
    }

    $frontendVersionPath = Join-Path $Inputs.FrontendTarget 'version.txt'
    $backendVersionPath = Join-Path $Inputs.BackendTarget 'version.txt'
    foreach ($spec in @(
        [pscustomobject]@{ Path = $frontendVersionPath; Label = 'Frontend/version.txt' },
        [pscustomobject]@{ Path = $backendVersionPath; Label = 'Backend/version.txt' }
    )) {
        try { $result.fingerprints += Get-ReadonlyFileFingerprint -Path $spec.Path -Label $spec.Label }
        catch { Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_PROTECTED_DATA_FAIL]' -CheckId 'protected' -Message $_.Exception.Message }
    }

    $markerCommit = $null
    if ($frontendExists -and $backendExists -and
        (Test-Path -LiteralPath $frontendVersionPath -PathType Leaf) -and
        (Test-Path -LiteralPath $backendVersionPath -PathType Leaf)) {
        $frontendMarker = (Get-Content -LiteralPath $frontendVersionPath -Raw -Encoding UTF8).Trim()
        $backendMarker = (Get-Content -LiteralPath $backendVersionPath -Raw -Encoding UTF8).Trim()
        if (-not $frontendMarker -or -not $frontendMarker.Equals($backendMarker, [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_VERSION_FAIL]' -CheckId 'target_version' -Message 'Frontend and Backend markers must match.'
        }
        else {
            $result.target_version = $frontendMarker
            try { $markerCommit = (Get-GitOutput -Arguments @('rev-parse', "$frontendMarker^{commit}") | Select-Object -First 1).Trim() }
            catch { Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_VERSION_FAIL]' -CheckId 'target_version' -Message "Marker does not resolve to a Git commit: $frontendMarker" }
            if ($markerCommit) {
                $priorPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    & git -C $RepoRoot merge-base --is-ancestor $markerCommit $result.head_commit 2>$null
                    $isAncestor = ($LASTEXITCODE -eq 0)
                }
                finally { $ErrorActionPreference = $priorPreference }
                if ([bool](Get-OptionalProperty -Object $observation -Name 'force_non_ancestor' -Default $false)) { $isAncestor = $false }
                if (-not $isAncestor) {
                    Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_VERSION_FAIL]' -CheckId 'target_version' -Message 'Marker commit is not an ancestor of HEAD.'
                    $markerCommit = $null
                }
            }
        }
    }
    else {
        Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_VERSION_FAIL]' -CheckId 'target_version' -Message 'One or both version markers are missing.'
    }
    $versionStatus = if (@($result.failures | Where-Object { $_.check_id -eq 'target_version' }).Count -gt 0) { 'fail' } else { 'pass' }
    Add-FormalPreflightCheck -Result $result -Id 'target_version' -Status $versionStatus -TruthSource 'Fixed formal target paths, marker bytes and Git commit ancestry' -Reason "target_version=$($result.target_version)"

    if ($markerCommit -and $frontendExists -and $backendExists) {
        try {
            $coherence = Get-FormalTargetCoherence -Inputs $Inputs -MarkerCommit $markerCommit
            $result.targets.frontend | Add-Member -NotePropertyName marker_commit -NotePropertyValue $markerCommit
            $result.targets.backend | Add-Member -NotePropertyName marker_commit -NotePropertyValue $markerCommit
            if ($coherence.missing.Count -gt 0 -or $coherence.extra.Count -gt 0 -or $coherence.blob_drift.Count -gt 0) {
                Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_TARGET_DRIFT]' -CheckId 'target_coherence' -Message "Managed target drift: missing=$($coherence.missing.Count), extra=$($coherence.extra.Count), blob=$($coherence.blob_drift.Count)."
                Add-FormalPreflightCheck -Result $result -Id 'target_coherence' -Status 'fail' -TruthSource 'Formal managed file set/blob versus marker commit tree' -Reason ($coherence | ConvertTo-Json -Depth 6 -Compress)
            }
            else {
                Add-FormalPreflightCheck -Result $result -Id 'target_coherence' -Status 'pass' -TruthSource 'Formal managed file set/blob versus marker commit tree' -Reason "Managed target matches marker commit ($($coherence.actual_count) files)."
            }
        }
        catch {
            Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_TARGET_DRIFT]' -CheckId 'target_coherence' -Message $_.Exception.Message
            Add-FormalPreflightCheck -Result $result -Id 'target_coherence' -Status 'fail' -TruthSource 'Formal managed file set/blob versus marker commit tree' -Reason $_.Exception.Message
        }
    }
    else {
        Add-FormalPreflightCheck -Result $result -Id 'target_coherence' -Status 'skipped' -TruthSource 'Formal managed file set/blob versus marker commit tree' -Reason 'Version prerequisite failed.'
    }

    if ($markerCommit) {
        $deletions = @(if ($fixtureMode) { Get-OptionalProperty -Object $observation -Name 'tracked_deletions' -Default @() } else { Get-GitOutput -Arguments @('diff', '--name-only', '--diff-filter=D', "$markerCommit..$($result.head_commit)", '--', 'Frontend', 'Backend') })
        $requirements = @(if ($fixtureMode) { Get-OptionalProperty -Object $observation -Name 'requirements_changes' -Default @() } else { Get-GitOutput -Arguments @('diff', '--name-only', "$markerCommit..$($result.head_commit)", '--', 'Frontend/requirements.txt', 'Backend/requirements.txt') })
        if ($deletions.Count -gt 0) { Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_SOURCE_DELETE]' -CheckId 'policy' -Message "Tracked deletion(s): $($deletions -join ', ')" }
        if ($requirements.Count -gt 0) { Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_POLICY_FAIL]' -CheckId 'policy' -Message "Requirements change(s): $($requirements -join ', ')" }
        $policyStatus = if ($deletions.Count -gt 0 -or $requirements.Count -gt 0) { 'fail' } else { 'pass' }
        Add-FormalPreflightCheck -Result $result -Id 'policy' -Status $policyStatus -TruthSource 'Git marker..HEAD tree diff' -Reason "tracked_deletions=$($deletions.Count), requirements_changes=$($requirements.Count)"
    }
    else {
        Add-FormalPreflightCheck -Result $result -Id 'policy' -Status 'skipped' -TruthSource 'Git marker..HEAD tree diff' -Reason 'Version prerequisite failed.'
    }

    $protectedUnreadable = @(Get-OptionalProperty -Object $observation -Name 'protected_unreadable' -Default @())
    foreach ($spec in @(
        [pscustomobject]@{ Path = (Join-Path $Inputs.FrontendTarget 'sentry_config.ini'); Label = 'Frontend/sentry_config.ini'; Required = $false },
        [pscustomobject]@{ Path = (Join-Path $Inputs.BackendTarget 'data\projects.json'); Label = 'Backend/data/projects.json'; Required = $true }
    )) {
        try {
            if ($spec.Label -in $protectedUnreadable) { throw "Injected unreadable protected data: $($spec.Label)" }
            $fingerprint = Get-ReadonlyFileFingerprint -Path $spec.Path -Label $spec.Label
            $result.fingerprints += $fingerprint
            if ($spec.Required -and -not $fingerprint.exists) { throw "Required protected data is missing: $($spec.Path)" }
            if (-not $spec.Required -and -not $fingerprint.exists) {
                Add-FormalPreflightWarning -Result $result -Tag '[UPGRADE_PROTECTED_DATA_OPTIONAL]' -CheckId 'protected' -Message "Optional protected file is absent: $($spec.Path)"
            }
        }
        catch { Add-FormalPreflightFailure -Result $result -Tag '[UPGRADE_PROTECTED_DATA_FAIL]' -CheckId 'protected' -Message $_.Exception.Message }
    }
    foreach ($registryRecord in @(Get-OptionalProperty -Object $observation -Name 'registry' -Default @())) {
        $registryFingerprint = Get-OptionalProperty -Object $registryRecord -Name 'fingerprint' -Default $null
        if ($registryFingerprint) { $result.fingerprints += $registryFingerprint }
    }
    $protectedStatus = if (@($result.failures | Where-Object { $_.check_id -eq 'protected' }).Count -gt 0) { 'fail' } else { 'pass' }
    Add-FormalPreflightCheck -Result $result -Id 'protected' -Status $protectedStatus -TruthSource 'Literal protected files via Get-Item and SHA-256' -Reason "fingerprints=$($result.fingerprints.Count)"

    Apply-PreflightProcessAssessment -Result $result -Observation $observation
    if ($result.failures.Count -eq 0) {
        $result.result = 'pass'
        $result.safe_to_upgrade = $true
    }
    else {
        $result.result = 'reject'
        $result.safe_to_upgrade = $false
    }
    return $result
}

# =========================
# TEMP-only mixed repair proof
# =========================

function Get-Utf8Sha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Assert-MixedRepoBasis {
    $branch = (Get-GitOutput -Arguments @('branch', '--show-current') | Select-Object -First 1).Trim()
    $head = Get-HeadCommit
    $originMain = (Get-GitOutput -Arguments @('rev-parse', 'origin/main') | Select-Object -First 1).Trim()
    $staged = @(Get-GitOutput -Arguments @('diff', '--cached', '--name-only'))
    if ($branch -ne 'main') { throw "[UPGRADE_MIXED_BASIS_FAIL] Expected branch main, got $branch." }
    [void](Assert-FormalPrepareCheckpointBasis -CurrentHead $head -FailureTag 'UPGRADE_MIXED_BASIS_FAIL')
    if (-not $originMain.Equals($MixedRepairOriginMain, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "[UPGRADE_MIXED_BASIS_FAIL] origin/main changed: $originMain"
    }
    if ($staged.Count -gt 0) {
        throw "[UPGRADE_MIXED_BASIS_FAIL] Staged changes are forbidden: $($staged -join ', ')"
    }
}

function Assert-MixedObservationSafe {
    param([Parameter(Mandatory = $true)][string]$Path)
    $observation = Read-PreflightFixtureObservation -Path $Path
    if ([bool](Get-OptionalProperty -Object $observation -Name 'lock_exists' -Default $false)) {
        throw '[UPGRADE_MIXED_RUNTIME_FAIL] Fixture lock must be absent.'
    }
    foreach ($name in @('ui', 'daemon', 'workers')) {
        if (@(Get-OptionalProperty -Object $observation -Name $name -Default @()).Count -gt 0) {
            throw "[UPGRADE_MIXED_RUNTIME_FAIL] Fixture $name process set must be empty."
        }
    }
    foreach ($record in @(Get-OptionalProperty -Object $observation -Name 'registry' -Default @())) {
        if ([bool](Get-OptionalProperty -Object $record -Name 'proc_exists' -Default $false) -or
            [bool](Get-OptionalProperty -Object $record -Name 'owned' -Default $false) -or
            [bool](Get-OptionalProperty -Object $record -Name 'ambiguous' -Default $false)) {
            throw '[UPGRADE_MIXED_RUNTIME_FAIL] Only stale, non-owned, non-ambiguous registry evidence is allowed.'
        }
    }
    return $observation
}

function New-MixedFileRecord {
    param(
        [Parameter(Mandatory = $true)][string]$RecordType,
        [Parameter(Mandatory = $true)][string]$Side,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            record_type = $RecordType
            side = $Side
            relative_path = $RelativePath.Replace('\', '/')
            exists = $false
            length = $null
            sha256 = $null
            last_write_utc = $null
        }
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return [pscustomobject]@{
        record_type = $RecordType
        side = $Side
        relative_path = $RelativePath.Replace('\', '/')
        exists = $true
        length = [int64]$item.Length
        sha256 = Get-FileSha256 $Path
        last_write_utc = $item.LastWriteTimeUtc.ToString('o')
    }
}

function ConvertTo-MixedCanonicalLine {
    param([Parameter(Mandatory = $true)]$Record)
    $exists = if ([bool]$Record.exists) { '1' } else { '0' }
    $length = if ($null -eq $Record.length) { '-' } else { ([int64]$Record.length).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    $sha256 = if ($Record.sha256) { ([string]$Record.sha256).ToUpperInvariant() } else { '-' }
    $lastWrite = if ($Record.last_write_utc) { [string]$Record.last_write_utc } else { '-' }
    return "$($Record.record_type)|$($Record.side)|$($Record.relative_path)|$exists|$length|$sha256|$lastWrite"
}

function Get-MixedStateId {
    param(
        [Parameter(Mandatory = $true)][string]$Schema,
        [Parameter(Mandatory = $true)]$Records
    )
    $lines = @($Records | Sort-Object record_type, side, relative_path | ForEach-Object { ConvertTo-MixedCanonicalLine $_ })
    $canonical = (@("schema=$Schema") + $lines) -join "`n"
    return [pscustomobject]@{ id = 'sha256:' + (Get-Utf8Sha256 $canonical); canonical = $canonical }
}

function Get-MixedActualManagedFiles {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$GitPrefix,
        [Parameter(Mandatory = $true)][string[]]$Allowlist
    )
    $files = @()
    foreach ($entry in $Allowlist) {
        $path = Join-Path $TargetRoot $entry
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $files += Get-Item -LiteralPath $path -Force
        }
        elseif (Test-Path -LiteralPath $path -PathType Container) {
            $files += Get-ChildItem -LiteralPath $path -Recurse -File -Force | Where-Object {
                $_.FullName -notmatch '([\\/])(__pycache__|\.venv)([\\/])' -and $_.Extension -ne '.pyc'
            }
        }
    }
    return @($files | Sort-Object FullName -Unique | ForEach-Object {
        $relative = $_.FullName.Substring($TargetRoot.Length + 1).Replace('\', '/')
        [pscustomobject]@{ git_path = "$GitPrefix/$relative"; full_name = $_.FullName }
    })
}

function Resolve-MixedRepairLayout {
    param([Parameter(Mandatory = $true)]$Inputs)

    $expectedPaths = @(Get-ExpectedManagedGitPaths -Commit $MixedRepairTargetCommit)
    if ($expectedPaths.Count -ne 26) {
        throw "[UPGRADE_MIXED_SOURCE_FAIL] Expected 26 managed paths at 971ba49, got $($expectedPaths.Count)."
    }
    $actual = @()
    $actual += Get-MixedActualManagedFiles -TargetRoot $Inputs.FrontendTarget -GitPrefix 'Frontend' -Allowlist $FrontendAllowlist
    $actual += Get-MixedActualManagedFiles -TargetRoot $Inputs.BackendTarget -GitPrefix 'Backend' -Allowlist $BackendAllowlist
    $actualByPath = @{}
    foreach ($record in $actual) { $actualByPath[$record.git_path] = $record.full_name }

    $layout = @()
    foreach ($gitPath in $expectedPaths) {
        $side = if ($gitPath.StartsWith('Frontend/', [System.StringComparison]::Ordinal)) { 'Frontend' } else { 'Backend' }
        $relative = $gitPath.Substring($side.Length + 1)
        $targetRoot = if ($side -eq 'Frontend') { $Inputs.FrontendTarget } else { $Inputs.BackendTarget }
        $targetPath = Join-Path $targetRoot $relative.Replace('/', '\')
        $packageBlob = (Get-GitOutput -Arguments @('rev-parse', "$MixedRepairTargetCommit`:$gitPath") | Select-Object -First 1).Trim()
        $expectedSourceBlob = if ($gitPath -eq 'Frontend/src/backend/adapter.py') {
            (Get-GitOutput -Arguments @('rev-parse', "$MixedRepairAdapterCommit`:$gitPath") | Select-Object -First 1).Trim()
        }
        else { $packageBlob }
        $exists = $actualByPath.ContainsKey($gitPath)
        if (-not $exists) {
            if ($MixedFixtureVariant -ne 'OriginallyAbsent' -or $gitPath -ne $MixedRepairAbsentPath) {
                throw "[UPGRADE_MIXED_SOURCE_FAIL] Managed source is missing: $gitPath"
            }
        }
        else {
            $actualBlob = (Get-GitOutput -Arguments @('hash-object', '--', $targetPath) | Select-Object -First 1).Trim()
            if (-not $actualBlob.Equals($expectedSourceBlob, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "[UPGRADE_MIXED_SOURCE_FAIL] Unexpected source blob for $gitPath`: $actualBlob"
            }
        }
        $action = if (-not $exists) { 'add' } elseif ($expectedSourceBlob -eq $packageBlob) { 'verify_unchanged' } else { 'replace' }
        $layout += [pscustomobject]@{
            record_type = 'managed'
            side = $side
            relative_path = $relative
            git_path = $gitPath
            target_path = $targetPath
            existed_before = $exists
            source_git_blob = if ($exists) { $expectedSourceBlob } else { $null }
            package_git_blob = $packageBlob
            action = $action
        }
    }

    $extras = @($actual | Where-Object { $_.git_path -notin $expectedPaths } | Sort-Object git_path)
    if ($MixedFixtureVariant -eq 'ExtraDelete') {
        if ($extras.Count -ne 1 -or $extras[0].git_path -ne $MixedRepairExtraPath) {
            throw '[UPGRADE_MIXED_SOURCE_FAIL] ExtraDelete fixture requires exactly the ruled synthetic extra path.'
        }
        $extra = $extras[0]
        $layout += [pscustomobject]@{
            record_type = 'managed_extra'
            side = 'Frontend'
            relative_path = $MixedRepairExtraPath.Substring('Frontend/'.Length)
            git_path = $MixedRepairExtraPath
            target_path = $extra.full_name
            existed_before = $true
            source_git_blob = (Get-GitOutput -Arguments @('hash-object', '--', $extra.full_name) | Select-Object -First 1).Trim()
            package_git_blob = $null
            action = 'delete'
        }
    }
    elseif ($extras.Count -gt 0) {
        throw "[UPGRADE_MIXED_SOURCE_FAIL] Unexpected managed extra(s): $($extras.git_path -join ', ')"
    }

    if ($MixedFixtureVariant -eq 'Base') {
        if (@($layout | Where-Object { $_.action -eq 'replace' }).Count -ne 1 -or
            @($layout | Where-Object { $_.action -eq 'verify_unchanged' }).Count -ne 25) {
            throw '[UPGRADE_MIXED_SOURCE_FAIL] Base fixture must resolve to one adapter replace and 25 verify_unchanged records.'
        }
    }
    foreach ($markerPath in @((Join-Path $Inputs.FrontendTarget 'version.txt'), (Join-Path $Inputs.BackendTarget 'version.txt'))) {
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
            (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim() -ne $MixedRepairMarker) {
            throw "[UPGRADE_MIXED_SOURCE_FAIL] Source marker is not $MixedRepairMarker`: $markerPath"
        }
    }
    return $layout
}

function Get-MixedSourceSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Layout
    )
    $software = @()
    foreach ($record in $Layout) {
        $software += New-MixedFileRecord -RecordType $record.record_type -Side $record.side -RelativePath $record.relative_path -Path $record.target_path
    }
    $software += New-MixedFileRecord -RecordType 'marker' -Side 'Frontend' -RelativePath 'version.txt' -Path (Join-Path $Inputs.FrontendTarget 'version.txt')
    $software += New-MixedFileRecord -RecordType 'marker' -Side 'Backend' -RelativePath 'version.txt' -Path (Join-Path $Inputs.BackendTarget 'version.txt')

    $evidenceOnly = @(
        (New-MixedFileRecord -RecordType 'protected' -Side 'Frontend' -RelativePath 'sentry_config.ini' -Path (Join-Path $Inputs.FrontendTarget 'sentry_config.ini')),
        (New-MixedFileRecord -RecordType 'protected' -Side 'Backend' -RelativePath 'data/projects.json' -Path (Join-Path $Inputs.BackendTarget 'data\projects.json')),
        (New-MixedFileRecord -RecordType 'registry_observation' -Side 'Registry' -RelativePath 'observation.json' -Path $Inputs.PreflightObservationPath)
    )
    foreach ($required in $evidenceOnly) {
        if (-not $required.exists) { throw "[UPGRADE_MIXED_SOURCE_FAIL] Required evidence is missing: $($required.side)/$($required.relative_path)" }
    }
    $evidence = @($software) + @($evidenceOnly)
    $softwareId = Get-MixedStateId -Schema $MixedRepairSchema -Records $software
    $evidenceId = Get-MixedStateId -Schema $MixedRepairSchema -Records $evidence
    return [pscustomobject]@{
        schema = $MixedRepairSchema
        software_records = @($software | Sort-Object record_type, side, relative_path)
        evidence_records = @($evidence | Sort-Object record_type, side, relative_path)
        software_state_id = $softwareId.id
        evidence_state_id = $evidenceId.id
        software_canonical = $softwareId.canonical
        evidence_canonical = $evidenceId.canonical
    }
}

function Get-MixedUnmanagedSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Layout
    )
    $owned = @{}
    foreach ($record in $Layout) { $owned[(Get-NormalizedFullPath $record.target_path)] = $true }
    foreach ($path in @(
        (Join-Path $Inputs.FrontendTarget 'sentry_config.ini'),
        (Join-Path $Inputs.FrontendTarget 'version.txt'),
        (Join-Path $Inputs.BackendTarget 'data\projects.json'),
        (Join-Path $Inputs.BackendTarget 'version.txt')
    )) { $owned[(Get-NormalizedFullPath $path)] = $true }

    $records = @()
    foreach ($sideSpec in @(
        [pscustomobject]@{ Side = 'Frontend'; Root = $Inputs.FrontendTarget },
        [pscustomobject]@{ Side = 'Backend'; Root = $Inputs.BackendTarget }
    )) {
        foreach ($file in @(Get-ChildItem -LiteralPath $sideSpec.Root -Recurse -File -Force | Sort-Object FullName)) {
            if ($owned.ContainsKey((Get-NormalizedFullPath $file.FullName))) { continue }
            $relative = $file.FullName.Substring($sideSpec.Root.Length + 1).Replace('\', '/')
            $records += New-MixedFileRecord -RecordType 'unmanaged_guard' -Side $sideSpec.Side -RelativePath $relative -Path $file.FullName
        }
    }
    $state = Get-MixedStateId -Schema 'laplace-mixed-unmanaged-guard-v1' -Records $records
    return [pscustomobject]@{ records = @($records | Sort-Object side, relative_path); state_id = $state.id; canonical = $state.canonical }
}

function Copy-MixedEvidenceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][string]$ExpectedLastWriteUtc
    )
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    [System.IO.File]::SetLastWriteTimeUtc($Destination, [DateTime]::Parse($ExpectedLastWriteUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind))
    if (-not (Get-FileSha256 $Destination).Equals($ExpectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "[UPGRADE_MIXED_PREPARE_FAIL] Evidence copy hash mismatch: $Destination"
    }
}

function Export-MixedGitPackage {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Layout
    )
    $packageRoot = Join-Path $Inputs.StagingRoot 'package'
    $archivePath = Join-Path $Inputs.StagingRoot 'package.zip'
    New-Item -ItemType Directory -Path $Inputs.StagingRoot -Force | Out-Null
    $pathSpecs = @()
    $pathSpecs += @($FrontendAllowlist | ForEach-Object { 'Frontend/' + $_.Replace('\', '/') })
    $pathSpecs += @($BackendAllowlist | ForEach-Object { 'Backend/' + $_.Replace('\', '/') })
    [void](Get-GitOutput -Arguments (@('archive', '--format=zip', "--output=$archivePath", $MixedRepairTargetCommit, '--') + $pathSpecs))
    Expand-Archive -LiteralPath $archivePath -DestinationPath $packageRoot -Force
    Remove-Item -LiteralPath $archivePath -Force

    if ($MixedFailureInjection -eq 'Package') {
        'corrupt-package' | Add-Content -LiteralPath (Join-Path $packageRoot 'Frontend\src\backend\adapter.py') -Encoding UTF8
    }
    $records = @{}
    foreach ($record in @($Layout | Where-Object { $_.package_git_blob })) {
        $packagePath = Join-Path $packageRoot $record.git_path.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
            throw "[UPGRADE_MIXED_PREPARE_FAIL] Package file is missing: $($record.git_path)"
        }
        $packageBlob = (Get-GitOutput -Arguments @('hash-object', '--', $packagePath) | Select-Object -First 1).Trim()
        if (-not $packageBlob.Equals($record.package_git_blob, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_MIXED_PREPARE_FAIL] Package Git blob mismatch: $($record.git_path)"
        }
        $item = Get-Item -LiteralPath $packagePath -Force
        $records[$record.git_path] = [pscustomobject]@{
            path = $packagePath
            sha256 = Get-FileSha256 $packagePath
            length = [int64]$item.Length
            last_write_utc = $item.LastWriteTimeUtc.ToString('o')
        }
    }
    $packagePaths = @()
    foreach ($side in @('Frontend', 'Backend')) {
        $sideRoot = Join-Path $packageRoot $side
        foreach ($file in @(Get-ChildItem -LiteralPath $sideRoot -Recurse -File -Force)) {
            $packagePaths += "$side/" + $file.FullName.Substring($sideRoot.Length + 1).Replace('\', '/')
        }
    }
    $expectedPackagePaths = @($Layout | Where-Object { $_.package_git_blob } | ForEach-Object { $_.git_path } | Sort-Object)
    if ((@($packagePaths | Sort-Object) -join "`n") -cne ($expectedPackagePaths -join "`n")) {
        throw '[UPGRADE_MIXED_PREPARE_FAIL] Package tree is not the exact ruled 26-file set.'
    }
    $markerRoot = Join-Path $packageRoot 'version-markers'
    New-Item -ItemType Directory -Path $markerRoot -Force | Out-Null
    $markers = @{}
    foreach ($side in @('Backend', 'Frontend')) {
        $path = Join-Path $markerRoot "$side-version.txt"
        $MixedRepairTargetCommit.Substring(0, 7) | Set-Content -LiteralPath $path -Encoding ASCII -NoNewline
        $item = Get-Item -LiteralPath $path -Force
        $markers[$side] = [pscustomobject]@{ path = $path; sha256 = Get-FileSha256 $path; length = [int64]$item.Length; last_write_utc = $item.LastWriteTimeUtc.ToString('o') }
    }
    return [pscustomobject]@{ root = $packageRoot; files = $records; markers = $markers }
}

function New-MixedPreimage {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Layout
    )
    $root = Join-Path $Inputs.StagingRoot 'preimage'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $managed = @{}
    foreach ($record in $Layout) {
        $sourceRecord = New-MixedFileRecord -RecordType $record.record_type -Side $record.side -RelativePath $record.relative_path -Path $record.target_path
        $preimagePath = if ($sourceRecord.exists) { Join-Path $root ("managed\$($record.side)\" + $record.relative_path.Replace('/', '\')) } else { $null }
        if ($sourceRecord.exists) {
            Copy-MixedEvidenceFile -Source $record.target_path -Destination $preimagePath -ExpectedHash $sourceRecord.sha256 -ExpectedLastWriteUtc $sourceRecord.last_write_utc
            if ($MixedFailureInjection -eq 'Preimage' -and $record.git_path -eq 'Frontend/src/backend/adapter.py') {
                'corrupt-preimage' | Add-Content -LiteralPath $preimagePath -Encoding UTF8
            }
            if (-not (Get-FileSha256 $preimagePath).Equals($sourceRecord.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "[UPGRADE_MIXED_PREPARE_FAIL] Managed preimage verification failed: $($record.git_path)"
            }
        }
        $managed[$record.git_path] = [pscustomobject]@{ source = $sourceRecord; path = $preimagePath }
    }

    $protected = @()
    foreach ($spec in @(
        [pscustomobject]@{ Side = 'Frontend'; Relative = 'sentry_config.ini'; Path = (Join-Path $Inputs.FrontendTarget 'sentry_config.ini') },
        [pscustomobject]@{ Side = 'Backend'; Relative = 'data/projects.json'; Path = (Join-Path $Inputs.BackendTarget 'data\projects.json') },
        [pscustomobject]@{ Side = 'Frontend'; Relative = 'version.txt'; Path = (Join-Path $Inputs.FrontendTarget 'version.txt') },
        [pscustomobject]@{ Side = 'Backend'; Relative = 'version.txt'; Path = (Join-Path $Inputs.BackendTarget 'version.txt') }
    )) {
        $sourceRecord = New-MixedFileRecord -RecordType 'protected_preimage' -Side $spec.Side -RelativePath $spec.Relative -Path $spec.Path
        if (-not $sourceRecord.exists) { throw "[UPGRADE_MIXED_PREPARE_FAIL] Required protected preimage is missing: $($spec.Path)" }
        $destination = Join-Path $root ("protected\$($spec.Side)\" + $spec.Relative.Replace('/', '\'))
        Copy-MixedEvidenceFile -Source $spec.Path -Destination $destination -ExpectedHash $sourceRecord.sha256 -ExpectedLastWriteUtc $sourceRecord.last_write_utc
        $protected += [pscustomobject]@{
            side = $spec.Side
            relative_path = $spec.Relative
            target_path = $spec.Path
            preimage_path = $destination
            preimage_sha256 = $sourceRecord.sha256
            length = $sourceRecord.length
            last_write_utc = $sourceRecord.last_write_utc
        }
    }
    return [pscustomobject]@{ root = $root; managed = $managed; protected = $protected }
}

function Copy-FileAtomicVerified {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Destination.$TransactionId.tmp"
    Copy-Item -LiteralPath $Source -Destination $temporary -Force
    if (-not (Get-FileSha256 $temporary).Equals($ExpectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "[UPGRADE_HASH_FAIL] Temporary copy hash mismatch: $Destination"
    }
    Move-Item -LiteralPath $temporary -Destination $Destination -Force
    if (-not (Get-FileSha256 $Destination).Equals($ExpectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "[UPGRADE_HASH_FAIL] Installed file hash mismatch: $Destination"
    }
}

function Save-TransactionJournal {
    param(
        [Parameter(Mandatory = $true)][string]$JournalPath,
        [Parameter(Mandatory = $true)]$Journal
    )
    $Journal.updated_at_utc = [DateTime]::UtcNow.ToString('o')
    Write-JsonAtomic -Path $JournalPath -Payload $Journal
}

function Get-ProtectedSnapshot {
    param([Parameter(Mandatory = $true)]$Inputs)
    $records = @()
    foreach ($item in $ProtectedBackupItems) {
        if ($item.RelativePath -eq 'version.txt') { continue }
        $targetRoot = if ($item.Side -eq 'Frontend') { $Inputs.FrontendTarget } else { $Inputs.BackendTarget }
        $path = Join-Path $targetRoot $item.RelativePath
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $records += [pscustomobject]@{ side = $item.Side; relative_path = $item.RelativePath; path = $path; existed_before = $true; sha256 = Get-FileSha256 $path }
        }
        elseif ($item.Required) {
            throw "[UPGRADE_PROTECTED_FAIL] Required protected data is missing: $path"
        }
        else {
            $records += [pscustomobject]@{ side = $item.Side; relative_path = $item.RelativePath; path = $path; existed_before = $false; sha256 = $null }
        }
    }
    return $records
}

function Assert-ProtectedSnapshotUnchanged {
    param([Parameter(Mandatory = $true)]$Records)
    foreach ($record in $Records) {
        $existsNow = Test-Path -LiteralPath $record.path -PathType Leaf
        if ($record.existed_before -ne $existsNow) {
            throw "[UPGRADE_PROTECTED_FAIL] Protected file existence changed: $($record.path)"
        }
        if ($existsNow -and -not (Get-FileSha256 $record.path).Equals($record.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_PROTECTED_FAIL] Protected file hash changed: $($record.path)"
        }
    }
}

function New-IsolatedTransaction {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$Version
    )
    $transactionId = [Guid]::NewGuid().ToString('N')
    $packageRoot = Join-Path $Inputs.StagingRoot 'package'
    $preimageRoot = Join-Path $Inputs.StagingRoot 'managed-preimage'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $preimageRoot -Force | Out-Null

    $fileRecords = @()
    $manifestLines = @()
    foreach ($side in @('frontend', 'backend')) {
        $sideName = if ($side -eq 'frontend') { 'Frontend' } else { 'Backend' }
        $targetRoot = if ($side -eq 'frontend') { $Inputs.FrontendTarget } else { $Inputs.BackendTarget }
        foreach ($file in $Plan.files[$side]) {
            $packagePath = Join-Path (Join-Path $packageRoot $sideName) $file.RelativePath
            Copy-FilePreservingRelativePath -SourcePath $file.FullName -RelativePath $file.RelativePath -DestinationRoot (Join-Path $packageRoot $sideName)
            $packageHash = Get-FileSha256 $packagePath
            $targetPath = Join-Path $targetRoot $file.RelativePath
            $existedBefore = Test-Path -LiteralPath $targetPath -PathType Leaf
            $preimagePath = $null
            $preimageHash = $null
            if ($existedBefore) {
                $preimagePath = Join-Path (Join-Path $preimageRoot $sideName) $file.RelativePath
                Copy-FilePreservingRelativePath -SourcePath $targetPath -RelativePath $file.RelativePath -DestinationRoot (Join-Path $preimageRoot $sideName)
                $preimageHash = Get-FileSha256 $preimagePath
            }
            $fileRecords += [pscustomobject]@{
                side = $sideName
                relative_path = $file.RelativePath
                package_path = $packagePath
                package_sha256 = $packageHash
                target_path = $targetPath
                existed_before = $existedBefore
                preimage_path = $preimagePath
                preimage_sha256 = $preimageHash
                apply_state = 'pending'
                applied_sha256 = $null
                restore_state = 'pending'
                restored_sha256 = $null
            }
            $manifestLines += "$sideName|$($file.RelativePath.Replace('\', '/'))|$packageHash"
        }
    }
    $manifestText = ($manifestLines | Sort-Object) -join "`n"
    $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestText)
    $manifestHash = ([System.BitConverter]::ToString(([System.Security.Cryptography.SHA256]::Create()).ComputeHash($manifestBytes))).Replace('-', '')
    $protected = @(Get-ProtectedSnapshot -Inputs $Inputs)
    $versionRecords = @()
    foreach ($versionSide in @(
        [pscustomobject]@{ Name = 'Frontend'; Target = $Version.FrontendPath },
        [pscustomobject]@{ Name = 'Backend'; Target = $Version.BackendPath }
    )) {
        $versionPackagePath = Join-Path (Join-Path $packageRoot 'version-markers') ("$($versionSide.Name)-version.txt")
        $versionPackageParent = Split-Path -Parent $versionPackagePath
        New-Item -ItemType Directory -Path $versionPackageParent -Force | Out-Null
        $Version.NewVersion | Set-Content -LiteralPath $versionPackagePath -Encoding ASCII -NoNewline
        $versionPreimagePath = Join-Path (Join-Path $preimageRoot 'version-markers') ("$($versionSide.Name)-version.txt")
        $versionPreimageParent = Split-Path -Parent $versionPreimagePath
        New-Item -ItemType Directory -Path $versionPreimageParent -Force | Out-Null
        Copy-Item -LiteralPath $versionSide.Target -Destination $versionPreimagePath -Force
        $versionRecords += [pscustomobject]@{
            side = $versionSide.Name
            target_path = $versionSide.Target
            old_value = $Version.OldVersion
            new_value = $Version.NewVersion
            package_path = $versionPackagePath
            package_sha256 = Get-FileSha256 $versionPackagePath
            preimage_path = $versionPreimagePath
            preimage_sha256 = Get-FileSha256 $versionPreimagePath
            apply_state = 'pending'
            applied_sha256 = $null
            restore_state = 'pending'
            restored_sha256 = $null
        }
    }
    return [pscustomobject]@{
        schema_version = 1
        transaction_id = $transactionId
        state = 'prepared'
        head_commit = $Version.HeadCommit
        manifest_sha256 = $manifestHash
        old_version = $Version.OldVersion
        new_version = $Version.NewVersion
        targets = [pscustomobject]@{ frontend = $Inputs.FrontendTarget; backend = $Inputs.BackendTarget }
        isolation_root = $Inputs.IsolationRoot
        staging_root = $Inputs.StagingRoot
        last_completed_step = 'prepared'
        failed_file = $null
        failure_injection = $FailureInjection
        process_policy = [pscustomobject]@{
            behavior = 'journal-only-no-process-operations'
            ui = 'future formal preflight rejects exact owned UI process or QLockFile; user exits normally; no force termination or auto-restart'
            workers = 'future formal flow restores exact live ownership set only; stale registry is neither restored nor cleaned; paper watcher excluded'
            fake_snapshot = @()
        }
        protected = $protected
        files = $fileRecords
        versions = $versionRecords
        created_at_utc = [DateTime]::UtcNow.ToString('o')
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
}

function Invoke-IsolatedRollback {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$JournalPath,
        [switch]$PermitInjectedFailure
    )
    $Journal.state = 'rolling_back'
    Save-TransactionJournal -JournalPath $JournalPath -Journal $Journal
    try {
        for ($index = $Journal.versions.Count - 1; $index -ge 0; $index--) {
            $record = $Journal.versions[$index]
            if ($record.apply_state -ne 'applied') { continue }
            $Journal.failed_file = $record.target_path
            if ($PermitInjectedFailure -and $FailureInjection -eq 'Rollback') {
                throw '[UPGRADE_INJECTED_FAIL] Rollback restore injection.'
            }
            Copy-FileAtomicVerified -Source $record.preimage_path -Destination $record.target_path -ExpectedHash $record.preimage_sha256 -TransactionId $Journal.transaction_id
            $record.restored_sha256 = Get-FileSha256 $record.target_path
            $record.restore_state = 'restored'
            $Journal.last_completed_step = "restore-version-$($record.side)"
            Save-TransactionJournal -JournalPath $JournalPath -Journal $Journal
        }
        for ($index = $Journal.files.Count - 1; $index -ge 0; $index--) {
            $record = $Journal.files[$index]
            if ($record.apply_state -ne 'applied') { continue }
            $Journal.failed_file = $record.target_path
            if ($PermitInjectedFailure -and $FailureInjection -eq 'Rollback') {
                throw '[UPGRADE_INJECTED_FAIL] Rollback restore injection.'
            }
            if ($record.existed_before) {
                Copy-FileAtomicVerified -Source $record.preimage_path -Destination $record.target_path -ExpectedHash $record.preimage_sha256 -TransactionId $Journal.transaction_id
                $record.restored_sha256 = Get-FileSha256 $record.target_path
            }
            elseif (Test-Path -LiteralPath $record.target_path -PathType Leaf) {
                Remove-Item -LiteralPath $record.target_path -Force
                if (Test-Path -LiteralPath $record.target_path) {
                    throw "[UPGRADE_ROLLBACK_FAIL] New file was not removed: $($record.target_path)"
                }
            }
            $record.restore_state = 'restored'
            $Journal.last_completed_step = "restore-$($record.side)-$($record.relative_path)"
            Save-TransactionJournal -JournalPath $JournalPath -Journal $Journal
        }
        Assert-ProtectedSnapshotUnchanged -Records $Journal.protected
        $Journal.failed_file = $null
        $Journal.state = 'rolled_back'
        $Journal.last_completed_step = 'rollback-complete'
        Save-TransactionJournal -JournalPath $JournalPath -Journal $Journal
    }
    catch {
        $Journal.state = 'rollback_failed'
        Save-TransactionJournal -JournalPath $JournalPath -Journal $Journal
        throw
    }
}

function Invoke-IsolatedApply {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$Version,
        [Parameter(Mandatory = $true)][string]$JournalPath
    )
    $journal = New-IsolatedTransaction -Inputs $Inputs -Plan $Plan -Version $Version
    Save-TransactionJournal -JournalPath $JournalPath -Journal $journal
    try {
        $journal.state = 'applying'
        Save-TransactionJournal -JournalPath $JournalPath -Journal $journal
        foreach ($side in @('Frontend', 'Backend')) {
            $sideApplied = 0
            foreach ($record in @($journal.files | Where-Object { $_.side -eq $side })) {
                $journal.failed_file = $record.target_path
                Copy-FileAtomicVerified -Source $record.package_path -Destination $record.target_path -ExpectedHash $record.package_sha256 -TransactionId $journal.transaction_id
                $record.apply_state = 'applied'
                $record.applied_sha256 = Get-FileSha256 $record.target_path
                $journal.last_completed_step = "apply-$side-$($record.relative_path)"
                Save-TransactionJournal -JournalPath $JournalPath -Journal $journal
                $sideApplied++
                if ($sideApplied -eq 1 -and $FailureInjection -eq "${side}Apply") {
                    throw "[UPGRADE_INJECTED_FAIL] $side apply injection."
                }
            }
        }
        foreach ($record in $journal.versions) {
            $journal.failed_file = $record.target_path
            Copy-FileAtomicVerified -Source $record.package_path -Destination $record.target_path -ExpectedHash $record.package_sha256 -TransactionId $journal.transaction_id
            $record.apply_state = 'applied'
            $record.applied_sha256 = Get-FileSha256 $record.target_path
            $journal.last_completed_step = "apply-version-$($record.side)"
            Save-TransactionJournal -JournalPath $JournalPath -Journal $journal
            if ($record.side -eq 'Frontend' -and $FailureInjection -eq 'Version') {
                throw '[UPGRADE_INJECTED_FAIL] Version injection.'
            }
        }
        foreach ($record in $journal.files) {
            if (-not (Get-FileSha256 $record.target_path).Equals($record.package_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "[UPGRADE_SMOKE_FAIL] Managed target hash mismatch: $($record.target_path)"
            }
        }
        Assert-ProtectedSnapshotUnchanged -Records $journal.protected
        if ($FailureInjection -in @('Smoke', 'Rollback')) {
            throw '[UPGRADE_INJECTED_FAIL] Smoke/rollback injection.'
        }
        $journal.failed_file = $null
        $journal.state = 'committed'
        $journal.last_completed_step = 'isolated-smoke-complete'
        Save-TransactionJournal -JournalPath $JournalPath -Journal $journal
        return $journal
    }
    catch {
        $applyError = $_
        try {
            Invoke-IsolatedRollback -Journal $journal -JournalPath $JournalPath -PermitInjectedFailure
        }
        catch {
            throw "[UPGRADE_ROLLBACK_FAIL] Apply failed: $($applyError.Exception.Message) Rollback failed: $($_.Exception.Message)"
        }
        throw $applyError
    }
}

function Assert-TransactionJournalBoundary {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Journal
    )
    if ($Journal.transaction_id -notmatch '^[0-9a-fA-F]{32}$') {
        throw '[UPGRADE_TRANSACTION_FAIL] Journal transaction ID is invalid.'
    }
    foreach ($pair in @(
        [pscustomobject]@{ Actual = $Journal.isolation_root; Expected = $Inputs.IsolationRoot; Label = 'IsolationRoot' },
        [pscustomobject]@{ Actual = $Journal.staging_root; Expected = $Inputs.StagingRoot; Label = 'StagingRoot' },
        [pscustomobject]@{ Actual = $Journal.targets.frontend; Expected = $Inputs.FrontendTarget; Label = 'FrontendTarget' },
        [pscustomobject]@{ Actual = $Journal.targets.backend; Expected = $Inputs.BackendTarget; Label = 'BackendTarget' }
    )) {
        if (-not (Get-NormalizedFullPath $pair.Actual).Equals((Get-NormalizedFullPath $pair.Expected), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_TRANSACTION_FAIL] Journal $($pair.Label) does not match the explicit rollback boundary."
        }
    }
    foreach ($record in $Journal.files) {
        $targetRoot = if ($record.side -eq 'Frontend') { $Inputs.FrontendTarget } elseif ($record.side -eq 'Backend') { $Inputs.BackendTarget } else { throw '[UPGRADE_TRANSACTION_FAIL] Journal file side is invalid.' }
        if (-not (Test-StrictPathInside -Candidate $record.target_path -Container $targetRoot)) {
            throw "[UPGRADE_TRANSACTION_FAIL] Journal managed target escaped its fake target: $($record.target_path)"
        }
        foreach ($evidencePath in @($record.package_path, $record.preimage_path)) {
            if ($evidencePath -and -not (Test-StrictPathInside -Candidate $evidencePath -Container $Inputs.StagingRoot)) {
                throw "[UPGRADE_TRANSACTION_FAIL] Journal evidence path escaped staging: $evidencePath"
            }
        }
    }
    foreach ($record in $Journal.versions) {
        $expectedTarget = if ($record.side -eq 'Frontend') { Join-Path $Inputs.FrontendTarget 'version.txt' } elseif ($record.side -eq 'Backend') { Join-Path $Inputs.BackendTarget 'version.txt' } else { throw '[UPGRADE_TRANSACTION_FAIL] Journal version side is invalid.' }
        if (-not (Get-NormalizedFullPath $record.target_path).Equals((Get-NormalizedFullPath $expectedTarget), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_TRANSACTION_FAIL] Journal version target escaped its fake target: $($record.target_path)"
        }
        foreach ($evidencePath in @($record.package_path, $record.preimage_path)) {
            if (-not (Test-StrictPathInside -Candidate $evidencePath -Container $Inputs.StagingRoot)) {
                throw "[UPGRADE_TRANSACTION_FAIL] Journal version evidence escaped staging: $evidencePath"
            }
        }
    }
}

function Invoke-ApplyIsolatedMode {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [AllowNull()]$Plan
    )
    $journalPath = Join-Path $Inputs.StagingRoot 'transaction-journal.json'
    if ($IsolatedAction -eq 'Rollback') {
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            throw '[UPGRADE_TRANSACTION_FAIL] Rollback requires an existing transaction journal.'
        }
        $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        Assert-TransactionJournalBoundary -Inputs $Inputs -Journal $journal
        if ($journal.state -eq 'committed') {
            throw '[UPGRADE_TRANSACTION_FAIL] A committed transaction is not eligible for automatic rollback.'
        }
        Invoke-IsolatedRollback -Journal $journal -JournalPath $journalPath
        return $journal
    }

    if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        $existing = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        throw "[UPGRADE_TRANSACTION_FAIL] Existing transaction state '$($existing.state)'; only explicit Rollback may continue an unfinished transaction."
    }
    if (Test-Path -LiteralPath $Inputs.StagingRoot) {
        $existingEntries = @(Get-ChildItem -LiteralPath $Inputs.StagingRoot -Force)
        if ($existingEntries.Count -gt 0) {
            throw '[UPGRADE_TRANSACTION_FAIL] Apply requires an empty or nonexistent StagingRoot.'
        }
    }
    Assert-ManagedSourcesMatchHead -Plan $Plan
    $version = Resolve-IsolatedVersionContract -Inputs $Inputs
    return Invoke-IsolatedApply -Inputs $Inputs -Plan $Plan -Version $version -JournalPath $journalPath
}

function Save-MixedRepairJournal {
    param(
        [Parameter(Mandatory = $true)][string]$JournalPath,
        [Parameter(Mandatory = $true)]$Journal
    )
    Save-TransactionJournal -JournalPath $JournalPath -Journal $Journal
    $stream = [System.IO.File]::Open($JournalPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    try { $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function Get-MixedJournalLayout {
    param([Parameter(Mandatory = $true)]$Journal)
    return @($Journal.files | ForEach-Object {
        [pscustomobject]@{
            record_type = $_.record_type
            side = $_.side
            relative_path = $_.relative_path
            git_path = $_.git_path
            target_path = $_.target_path
            action = $_.action
        }
    })
}

function Assert-MixedGuardsUnchanged {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Journal
    )
    [void](Assert-MixedObservationSafe -Path $Inputs.PreflightObservationPath)
    $currentGuards = @(
        (New-MixedFileRecord -RecordType 'protected' -Side 'Frontend' -RelativePath 'sentry_config.ini' -Path (Join-Path $Inputs.FrontendTarget 'sentry_config.ini')),
        (New-MixedFileRecord -RecordType 'protected' -Side 'Backend' -RelativePath 'data/projects.json' -Path (Join-Path $Inputs.BackendTarget 'data\projects.json')),
        (New-MixedFileRecord -RecordType 'registry_observation' -Side 'Registry' -RelativePath 'observation.json' -Path $Inputs.PreflightObservationPath)
    )
    $expectedGuards = @($Journal.source_manifest.evidence_records | Where-Object { $_.record_type -in @('protected', 'registry_observation') })
    $currentCanonical = @($currentGuards | Sort-Object record_type, side, relative_path | ForEach-Object { ConvertTo-MixedCanonicalLine $_ }) -join "`n"
    $expectedCanonical = @($expectedGuards | Sort-Object record_type, side, relative_path | ForEach-Object { ConvertTo-MixedCanonicalLine $_ }) -join "`n"
    if ($currentCanonical -cne $expectedCanonical) {
        throw '[UPGRADE_MIXED_GUARD_FAIL] Protected or registry observation evidence changed.'
    }
    $unmanaged = Get-MixedUnmanagedSnapshot -Inputs $Inputs -Layout (Get-MixedJournalLayout -Journal $Journal)
    if ($unmanaged.state_id -ne $Journal.unmanaged_guard.state_id -or $unmanaged.canonical -cne $Journal.unmanaged_guard.canonical) {
        throw '[UPGRADE_MIXED_GUARD_FAIL] Unmanaged target content or timestamps changed.'
    }
}

function Get-MixedSnapshotFromJournal {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Journal
    )
    $software = @()
    foreach ($record in $Journal.files) {
        $software += New-MixedFileRecord -RecordType $record.record_type -Side $record.side -RelativePath $record.relative_path -Path $record.target_path
    }
    foreach ($record in $Journal.versions) {
        $software += New-MixedFileRecord -RecordType 'marker' -Side $record.side -RelativePath 'version.txt' -Path $record.target_path
    }
    $evidence = @($software) + @(
        (New-MixedFileRecord -RecordType 'protected' -Side 'Frontend' -RelativePath 'sentry_config.ini' -Path (Join-Path $Inputs.FrontendTarget 'sentry_config.ini')),
        (New-MixedFileRecord -RecordType 'protected' -Side 'Backend' -RelativePath 'data/projects.json' -Path (Join-Path $Inputs.BackendTarget 'data\projects.json')),
        (New-MixedFileRecord -RecordType 'registry_observation' -Side 'Registry' -RelativePath 'observation.json' -Path $Inputs.PreflightObservationPath)
    )
    $softwareId = Get-MixedStateId -Schema $MixedRepairSchema -Records $software
    $evidenceId = Get-MixedStateId -Schema $MixedRepairSchema -Records $evidence
    return [pscustomobject]@{
        software_state_id = $softwareId.id
        evidence_state_id = $evidenceId.id
        software_canonical = $softwareId.canonical
        evidence_canonical = $evidenceId.canonical
    }
}

function New-MixedRepairTransaction {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)][string]$JournalPath
    )
    Assert-MixedRepoBasis
    [void](Assert-MixedObservationSafe -Path $Inputs.PreflightObservationPath)
    $layout = Resolve-MixedRepairLayout -Inputs $Inputs
    $sourceManifest = Get-MixedSourceSnapshot -Inputs $Inputs -Layout $layout
    $unmanagedGuard = Get-MixedUnmanagedSnapshot -Inputs $Inputs -Layout $layout

    $preimage = New-MixedPreimage -Inputs $Inputs -Layout $layout
    $package = Export-MixedGitPackage -Inputs $Inputs -Layout $layout
    $transactionId = [Guid]::NewGuid().ToString('N')
    $fileRecords = @()
    foreach ($record in $layout) {
        $preimageRecord = $preimage.managed[$record.git_path]
        $packageRecord = if ($record.package_git_blob) { $package.files[$record.git_path] } else { $null }
        $fileRecords += [pscustomobject]@{
            record_type = $record.record_type
            side = $record.side
            relative_path = $record.relative_path
            git_path = $record.git_path
            action = $record.action
            target_path = $record.target_path
            existed_before = [bool]$preimageRecord.source.exists
            source_length = $preimageRecord.source.length
            source_sha256 = $preimageRecord.source.sha256
            source_last_write_utc = $preimageRecord.source.last_write_utc
            preimage_path = $preimageRecord.path
            preimage_sha256 = $preimageRecord.source.sha256
            package_path = if ($packageRecord) { $packageRecord.path } else { $null }
            package_sha256 = if ($packageRecord) { $packageRecord.sha256 } else { $null }
            package_length = if ($packageRecord) { $packageRecord.length } else { $null }
            package_last_write_utc = if ($packageRecord) { $packageRecord.last_write_utc } else { $null }
            temp_path = "$($record.target_path).$transactionId.tmp"
            apply_state = 'pending'
            reconciled_state = 'unknown'
            temp_state = 'unknown'
            restore_state = 'pending'
        }
    }
    $versionRecords = @()
    foreach ($side in @('Backend', 'Frontend')) {
        $preimageRecord = @($preimage.protected | Where-Object { $_.side -eq $side -and $_.relative_path -eq 'version.txt' } | Select-Object -First 1)[0]
        $packageRecord = $package.markers[$side]
        $targetPath = if ($side -eq 'Backend') { Join-Path $Inputs.BackendTarget 'version.txt' } else { Join-Path $Inputs.FrontendTarget 'version.txt' }
        $versionRecords += [pscustomobject]@{
            record_type = 'marker'
            side = $side
            relative_path = 'version.txt'
            action = 'replace'
            target_path = $targetPath
            existed_before = $true
            source_length = $preimageRecord.length
            source_sha256 = $preimageRecord.preimage_sha256
            source_last_write_utc = $preimageRecord.last_write_utc
            preimage_path = $preimageRecord.preimage_path
            preimage_sha256 = $preimageRecord.preimage_sha256
            package_path = $packageRecord.path
            package_sha256 = $packageRecord.sha256
            package_length = $packageRecord.length
            package_last_write_utc = $packageRecord.last_write_utc
            temp_path = "$targetPath.$transactionId.tmp"
            apply_state = 'pending'
            reconciled_state = 'unknown'
            temp_state = 'unknown'
            restore_state = 'pending'
        }
    }
    $journal = [pscustomobject]@{
        schema_version = 2
        schema = $MixedRepairSchema
        transaction_id = $transactionId
        mode = 'RepairMixedIsolated'
        state = 'prepared'
        target_commit = $MixedRepairTargetCommit
        source_adapter_commit = $MixedRepairAdapterCommit
        source_marker = $MixedRepairMarker
        fixture_variant = $MixedFixtureVariant
        isolation_root = $Inputs.IsolationRoot
        staging_root = $Inputs.StagingRoot
        transaction_root = $Inputs.TransactionRoot
        observation_path = $Inputs.PreflightObservationPath
        targets = [pscustomobject]@{ frontend = $Inputs.FrontendTarget; backend = $Inputs.BackendTarget }
        source_manifest = $sourceManifest
        unmanaged_guard = $unmanagedGuard
        protected_preimage = @($preimage.protected | Where-Object { $_.relative_path -ne 'version.txt' })
        files = $fileRecords
        versions = $versionRecords
        events = @('prepared')
        failed_file = $null
        last_completed_step = 'prepared'
        created_at_utc = [DateTime]::UtcNow.ToString('o')
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    Save-MixedRepairJournal -JournalPath $JournalPath -Journal $journal
    if ($MixedFailureInjection -eq 'Prepare') {
        throw '[UPGRADE_MIXED_INJECTED_FAIL] Prepared-journal interruption before the second source snapshot.'
    }

    foreach ($path in @($Inputs.StagingRoot, $Inputs.TransactionRoot, $Inputs.FrontendTarget, $Inputs.BackendTarget, $Inputs.PreflightObservationPath)) {
        Assert-NoReparseAmbiguity -Path $path
    }
    [void](Assert-MixedObservationSafe -Path $Inputs.PreflightObservationPath)
    $secondLayout = Resolve-MixedRepairLayout -Inputs $Inputs
    $secondSource = Get-MixedSourceSnapshot -Inputs $Inputs -Layout $secondLayout
    $secondUnmanaged = Get-MixedUnmanagedSnapshot -Inputs $Inputs -Layout $secondLayout
    if ($secondSource.software_canonical -cne $sourceManifest.software_canonical -or
        $secondSource.evidence_canonical -cne $sourceManifest.evidence_canonical -or
        $secondUnmanaged.canonical -cne $unmanagedGuard.canonical) {
        $journal.state = 'prepare_invalidated'
        $journal.last_completed_step = 'second-snapshot-mismatch'
        Save-MixedRepairJournal -JournalPath $JournalPath -Journal $journal
        throw '[UPGRADE_MIXED_PREPARE_FAIL] Source/protected/process/unmanaged snapshot changed before the first target write.'
    }
    $journal.events += 'second-snapshot-verified'
    $journal.last_completed_step = 'second-snapshot-verified'
    Save-MixedRepairJournal -JournalPath $JournalPath -Journal $journal
    return $journal
}

function Copy-MixedFileAtomicVerified {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [string]$LastWriteUtc,
        [switch]$InjectBeforeReplace
    )
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Destination.$TransactionId.tmp"
    if (Test-Path -LiteralPath $temporary) {
        throw "[UPGRADE_MIXED_TRANSACTION_FAIL] Adjacent temporary already exists: $temporary"
    }
    Copy-Item -LiteralPath $Source -Destination $temporary -Force
    if (-not (Get-FileSha256 $temporary).Equals($ExpectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "[UPGRADE_MIXED_HASH_FAIL] Adjacent temporary hash mismatch: $Destination"
    }
    if ($InjectBeforeReplace) {
        throw '[UPGRADE_MIXED_INJECTED_FAIL] Adapter interruption after temporary verification and before replace.'
    }
    Move-Item -LiteralPath $temporary -Destination $Destination -Force
    if ($LastWriteUtc) {
        [System.IO.File]::SetLastWriteTimeUtc($Destination, [DateTime]::Parse($LastWriteUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind))
    }
    if (-not (Get-FileSha256 $Destination).Equals($ExpectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "[UPGRADE_MIXED_HASH_FAIL] Installed file hash mismatch: $Destination"
    }
}

function Assert-MixedManagedPackageState {
    param([Parameter(Mandatory = $true)]$Journal)
    foreach ($record in $Journal.files) {
        if ($record.action -eq 'delete') {
            if (Test-Path -LiteralPath $record.target_path) {
                throw "[UPGRADE_MIXED_POSTCHECK_FAIL] Deleted extra still exists: $($record.git_path)"
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $record.target_path -PathType Leaf) -or
            -not (Get-FileSha256 $record.target_path).Equals($record.package_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_MIXED_POSTCHECK_FAIL] Managed package mismatch: $($record.git_path)"
        }
        if ($record.action -eq 'verify_unchanged') {
            $mtime = (Get-Item -LiteralPath $record.target_path -Force).LastWriteTimeUtc.ToString('o')
            if ($mtime -ne $record.source_last_write_utc) {
                throw "[UPGRADE_MIXED_POSTCHECK_FAIL] verify_unchanged timestamp changed: $($record.git_path)"
            }
        }
    }
}

function Invoke-MixedRepairApply {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)][string]$JournalPath
    )
    $journal = New-MixedRepairTransaction -Inputs $Inputs -JournalPath $JournalPath
    $journal.state = 'applying'
    $journal.events += 'applying'
    Save-MixedRepairJournal -JournalPath $JournalPath -Journal $journal

    $mutations = @($journal.files | Where-Object { $_.action -ne 'verify_unchanged' } | Sort-Object @{ Expression = { if ($_.git_path -eq 'Frontend/src/backend/adapter.py') { 0 } else { 1 } } }, git_path)
    foreach ($record in $mutations) {
        $journal.failed_file = $record.target_path
        if ($record.action -eq 'delete') {
            if (-not (Test-Path -LiteralPath $record.target_path -PathType Leaf) -or
                -not (Get-FileSha256 $record.target_path).Equals($record.preimage_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "[UPGRADE_MIXED_APPLY_FAIL] Extra delete source changed: $($record.git_path)"
            }
            Remove-Item -LiteralPath $record.target_path -Force
        }
        else {
            $injectBefore = $record.git_path -eq 'Frontend/src/backend/adapter.py' -and $MixedFailureInjection -eq 'AdapterBeforeReplace'
            Copy-MixedFileAtomicVerified -Source $record.package_path -Destination $record.target_path -ExpectedHash $record.package_sha256 -TransactionId $journal.transaction_id -LastWriteUtc $record.package_last_write_utc -InjectBeforeReplace:$injectBefore
        }
        if ($record.git_path -eq 'Frontend/src/backend/adapter.py' -and $MixedFailureInjection -eq 'AdapterAfterReplace') {
            throw '[UPGRADE_MIXED_INJECTED_FAIL] Adapter was replaced before its journal record was updated.'
        }
        $record.apply_state = 'applied'
        $journal.events += "applied:$($record.git_path)"
        $journal.last_completed_step = "applied:$($record.git_path)"
        Save-MixedRepairJournal -JournalPath $JournalPath -Journal $journal
    }
    Assert-MixedManagedPackageState -Journal $journal
    $journal.events += 'managed-26-verified'
    $journal.last_completed_step = 'managed-26-verified'
    Save-MixedRepairJournal -JournalPath $JournalPath -Journal $journal

    foreach ($record in $journal.versions) {
        $journal.failed_file = $record.target_path
        Copy-MixedFileAtomicVerified -Source $record.package_path -Destination $record.target_path -ExpectedHash $record.package_sha256 -TransactionId $journal.transaction_id -LastWriteUtc $record.package_last_write_utc
        if ($record.side -eq 'Backend' -and $MixedFailureInjection -eq 'BackendMarkerAfterReplace') {
            throw '[UPGRADE_MIXED_INJECTED_FAIL] Backend marker was replaced before its journal record was updated.'
        }
        $record.apply_state = 'applied'
        $journal.events += "marker:$($record.side)"
        $journal.last_completed_step = "marker:$($record.side)"
        Save-MixedRepairJournal -JournalPath $JournalPath -Journal $journal
    }
    foreach ($record in $journal.versions) {
        if (-not (Get-FileSha256 $record.target_path).Equals($record.package_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_MIXED_POSTCHECK_FAIL] Marker package mismatch: $($record.side)"
        }
    }
    Assert-MixedManagedPackageState -Journal $journal
    Assert-MixedGuardsUnchanged -Inputs $Inputs -Journal $journal
    if ($MixedFailureInjection -eq 'PostCheck') {
        throw '[UPGRADE_MIXED_INJECTED_FAIL] Post-check interruption before pending acceptance commit.'
    }
    $journal.failed_file = $null
    $journal.state = 'committed_pending_acceptance'
    $journal.events += 'committed_pending_acceptance'
    $journal.last_completed_step = 'committed_pending_acceptance'
    Save-MixedRepairJournal -JournalPath $JournalPath -Journal $journal
    return $journal
}

function Get-MixedRecordDisposition {
    param([Parameter(Mandatory = $true)]$Record)
    $exists = Test-Path -LiteralPath $Record.target_path -PathType Leaf
    $hash = if ($exists) { Get-FileSha256 $Record.target_path } else { $null }
    $state = 'indeterminate'
    if ($Record.action -eq 'add') {
        if (-not $exists) { $state = 'preimage' }
        elseif ($hash.Equals($Record.package_sha256, [System.StringComparison]::OrdinalIgnoreCase)) { $state = 'applied' }
    }
    elseif ($Record.action -eq 'delete') {
        if (-not $exists) { $state = 'applied' }
        elseif ($hash.Equals($Record.preimage_sha256, [System.StringComparison]::OrdinalIgnoreCase)) { $state = 'preimage' }
    }
    elseif ($exists -and $hash.Equals($Record.preimage_sha256, [System.StringComparison]::OrdinalIgnoreCase) -and
        $hash.Equals($Record.package_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        $state = 'unchanged'
    }
    elseif ($exists -and $hash.Equals($Record.preimage_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        $state = 'preimage'
    }
    elseif ($exists -and $hash.Equals($Record.package_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        $state = 'applied'
    }

    $tempState = 'absent'
    if (Test-Path -LiteralPath $Record.temp_path -PathType Leaf) {
        $tempHash = Get-FileSha256 $Record.temp_path
        if ($Record.package_sha256 -and $tempHash.Equals($Record.package_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $tempState = 'package'
        }
        elseif ($Record.preimage_sha256 -and $tempHash.Equals($Record.preimage_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $tempState = 'preimage'
        }
        else { $tempState = 'indeterminate' }
    }
    return [pscustomobject]@{ state = $state; temp_state = $tempState }
}

function Assert-MixedRepairJournalBoundary {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Journal
    )
    if ($Journal.transaction_id -notmatch '^[0-9a-fA-F]{32}$' -or $Journal.schema -ne $MixedRepairSchema -or
        $Journal.mode -ne 'RepairMixedIsolated' -or $Journal.target_commit -ne $MixedRepairTargetCommit) {
        throw '[UPGRADE_MIXED_TRANSACTION_FAIL] Journal identity/schema/target commit is invalid.'
    }
    foreach ($pair in @(
        [pscustomobject]@{ Actual = $Journal.isolation_root; Expected = $Inputs.IsolationRoot; Label = 'IsolationRoot' },
        [pscustomobject]@{ Actual = $Journal.staging_root; Expected = $Inputs.StagingRoot; Label = 'StagingRoot' },
        [pscustomobject]@{ Actual = $Journal.transaction_root; Expected = $Inputs.TransactionRoot; Label = 'TransactionRoot' },
        [pscustomobject]@{ Actual = $Journal.targets.frontend; Expected = $Inputs.FrontendTarget; Label = 'FrontendTarget' },
        [pscustomobject]@{ Actual = $Journal.targets.backend; Expected = $Inputs.BackendTarget; Label = 'BackendTarget' },
        [pscustomobject]@{ Actual = $Journal.observation_path; Expected = $Inputs.PreflightObservationPath; Label = 'Observation' }
    )) {
        if (-not (Test-PathsEqual -First $pair.Actual -Second $pair.Expected)) {
            throw "[UPGRADE_MIXED_TRANSACTION_FAIL] Journal $($pair.Label) escaped its explicit boundary."
        }
    }
    foreach ($record in $Journal.files) {
        $targetRoot = if ($record.side -eq 'Frontend') { $Inputs.FrontendTarget } elseif ($record.side -eq 'Backend') { $Inputs.BackendTarget } else { throw '[UPGRADE_MIXED_TRANSACTION_FAIL] Journal file side is invalid.' }
        $expectedTarget = Join-Path $targetRoot ([string]$record.relative_path).Replace('/', '\')
        if (-not (Test-StrictPathInside -Candidate $record.target_path -Container $targetRoot) -or
            -not (Test-PathsEqual -First $record.target_path -Second $expectedTarget)) {
            throw "[UPGRADE_MIXED_TRANSACTION_FAIL] Target path escaped fake target: $($record.target_path)"
        }
        $expectedTemp = "$($record.target_path).$($Journal.transaction_id).tmp"
        if (-not (Test-PathsEqual -First $record.temp_path -Second $expectedTemp)) {
            throw "[UPGRADE_MIXED_TRANSACTION_FAIL] Adjacent temporary path is invalid: $($record.temp_path)"
        }
        if ($record.action -notin @('verify_unchanged', 'replace', 'add', 'delete')) {
            throw "[UPGRADE_MIXED_TRANSACTION_FAIL] Unknown managed action: $($record.action)"
        }
        foreach ($path in @($record.preimage_path, $record.package_path)) {
            if ($path -and -not (Test-StrictPathInside -Candidate $path -Container $Inputs.StagingRoot)) {
                throw "[UPGRADE_MIXED_TRANSACTION_FAIL] Evidence path escaped staging: $path"
            }
        }
    }
    foreach ($record in $Journal.versions) {
        $targetRoot = if ($record.side -eq 'Frontend') { $Inputs.FrontendTarget } elseif ($record.side -eq 'Backend') { $Inputs.BackendTarget } else { throw '[UPGRADE_MIXED_TRANSACTION_FAIL] Journal marker side is invalid.' }
        $expectedTarget = Join-Path $targetRoot 'version.txt'
        $expectedTemp = "$expectedTarget.$($Journal.transaction_id).tmp"
        if (-not (Test-PathsEqual -First $record.target_path -Second $expectedTarget) -or
            -not (Test-PathsEqual -First $record.temp_path -Second $expectedTemp)) {
            throw "[UPGRADE_MIXED_TRANSACTION_FAIL] Marker target/temp path is invalid: $($record.target_path)"
        }
        foreach ($path in @($record.preimage_path, $record.package_path)) {
            if (-not (Test-StrictPathInside -Candidate $path -Container $Inputs.StagingRoot)) {
                throw "[UPGRADE_MIXED_TRANSACTION_FAIL] Marker evidence escaped staging: $path"
            }
        }
    }
    foreach ($record in $Journal.protected_preimage) {
        $targetRoot = if ($record.side -eq 'Frontend') { $Inputs.FrontendTarget } elseif ($record.side -eq 'Backend') { $Inputs.BackendTarget } else { throw '[UPGRADE_MIXED_TRANSACTION_FAIL] Protected side is invalid.' }
        $expectedTarget = Join-Path $targetRoot ([string]$record.relative_path).Replace('/', '\')
        if (-not (Test-PathsEqual -First $record.target_path -Second $expectedTarget) -or
            -not (Test-StrictPathInside -Candidate $record.preimage_path -Container $Inputs.StagingRoot)) {
            throw "[UPGRADE_MIXED_TRANSACTION_FAIL] Protected preimage boundary is invalid: $($record.target_path)"
        }
    }
}

function Assert-MixedJournalEvidenceIntegrity {
    param([Parameter(Mandatory = $true)]$Journal)

    foreach ($state in @(
        [pscustomobject]@{ Canonical = $Journal.source_manifest.software_canonical; Id = $Journal.source_manifest.software_state_id; Label = 'software source manifest' },
        [pscustomobject]@{ Canonical = $Journal.source_manifest.evidence_canonical; Id = $Journal.source_manifest.evidence_state_id; Label = 'evidence source manifest' },
        [pscustomobject]@{ Canonical = $Journal.unmanaged_guard.canonical; Id = $Journal.unmanaged_guard.state_id; Label = 'unmanaged guard' }
    )) {
        $actual = 'sha256:' + (Get-Utf8Sha256 ([string]$state.Canonical))
        if (-not $actual.Equals([string]$state.Id, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_MIXED_INDETERMINATE] Journal $($state.Label) ID does not match its canonical records."
        }
    }
    foreach ($record in @($Journal.files) + @($Journal.versions)) {
        foreach ($evidence in @(
            [pscustomobject]@{ Path = $record.preimage_path; Hash = $record.preimage_sha256; Required = [bool]$record.existed_before; Label = 'preimage' },
            [pscustomobject]@{ Path = $record.package_path; Hash = $record.package_sha256; Required = ($record.action -ne 'delete'); Label = 'package' }
        )) {
            if (-not $evidence.Required) { continue }
            if (-not (Test-Path -LiteralPath $evidence.Path -PathType Leaf) -or
                -not (Get-FileSha256 $evidence.Path).Equals([string]$evidence.Hash, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "[UPGRADE_MIXED_INDETERMINATE] Transaction $($evidence.Label) evidence is missing or changed: $($evidence.Path)"
            }
        }
    }
    foreach ($record in $Journal.protected_preimage) {
        if (-not (Test-Path -LiteralPath $record.preimage_path -PathType Leaf) -or
            -not (Get-FileSha256 $record.preimage_path).Equals([string]$record.preimage_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_MIXED_INDETERMINATE] Protected preimage evidence is missing or changed: $($record.preimage_path)"
        }
    }
}

function Invoke-MixedRepairRollback {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$JournalPath
    )
    Assert-MixedRepairJournalBoundary -Inputs $Inputs -Journal $Journal
    Assert-MixedJournalEvidenceIntegrity -Journal $Journal
    if ($Journal.state -eq 'rolled_back') { throw '[UPGRADE_MIXED_TRANSACTION_FAIL] Transaction is already rolled back.' }

    $indeterminate = @()
    foreach ($record in @($Journal.files) + @($Journal.versions)) {
        $disposition = Get-MixedRecordDisposition -Record $record
        $record.reconciled_state = $disposition.state
        $record.temp_state = $disposition.temp_state
        if ($disposition.state -eq 'indeterminate' -or $disposition.temp_state -eq 'indeterminate') {
            $indeterminate += $record.target_path
        }
    }
    if ($indeterminate.Count -gt 0) {
        $Journal.state = 'indeterminate'
        $Journal.failed_file = $indeterminate[0]
        $Journal.last_completed_step = 'reconciliation-indeterminate'
        Save-MixedRepairJournal -JournalPath $JournalPath -Journal $Journal
        throw "[UPGRADE_MIXED_INDETERMINATE] Unknown target/temp hash requires human adjudication: $($indeterminate -join ', ')"
    }

    $Journal.state = 'rolling_back'
    $Journal.events += 'reconciled-from-target-hashes'
    $Journal.last_completed_step = 'reconciled-from-target-hashes'
    Save-MixedRepairJournal -JournalPath $JournalPath -Journal $Journal
    foreach ($record in @($Journal.files) + @($Journal.versions)) {
        if ($record.temp_state -in @('package', 'preimage') -and (Test-Path -LiteralPath $record.temp_path -PathType Leaf)) {
            Remove-Item -LiteralPath $record.temp_path -Force
        }
    }

    for ($index = $Journal.files.Count - 1; $index -ge 0; $index--) {
        $record = $Journal.files[$index]
        if ($record.reconciled_state -eq 'applied') {
            if ($record.action -eq 'add') {
                if (-not (Get-FileSha256 $record.target_path).Equals($record.package_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "[UPGRADE_MIXED_INDETERMINATE] Added file changed before rollback: $($record.git_path)"
                }
                Remove-Item -LiteralPath $record.target_path -Force
            }
            else {
                Copy-MixedFileAtomicVerified -Source $record.preimage_path -Destination $record.target_path -ExpectedHash $record.preimage_sha256 -TransactionId $Journal.transaction_id -LastWriteUtc $record.source_last_write_utc
            }
        }
        $record.restore_state = 'restored'
        $Journal.last_completed_step = "restore-managed:$($record.git_path)"
        Save-MixedRepairJournal -JournalPath $JournalPath -Journal $Journal
    }
    foreach ($record in $Journal.files) {
        $exists = Test-Path -LiteralPath $record.target_path -PathType Leaf
        if ([bool]$record.existed_before -ne $exists) {
            throw "[UPGRADE_MIXED_ROLLBACK_FAIL] Managed existence was not restored: $($record.git_path)"
        }
        if ($exists) {
            if (-not (Get-FileSha256 $record.target_path).Equals($record.preimage_sha256, [System.StringComparison]::OrdinalIgnoreCase) -or
                (Get-Item -LiteralPath $record.target_path -Force).LastWriteTimeUtc.ToString('o') -ne $record.source_last_write_utc) {
                throw "[UPGRADE_MIXED_ROLLBACK_FAIL] Managed preimage was not restored exactly: $($record.git_path)"
            }
        }
    }
    $Journal.events += 'managed-preimage-restored'
    Save-MixedRepairJournal -JournalPath $JournalPath -Journal $Journal

    for ($index = $Journal.versions.Count - 1; $index -ge 0; $index--) {
        $record = $Journal.versions[$index]
        if ($record.reconciled_state -eq 'applied') {
            Copy-MixedFileAtomicVerified -Source $record.preimage_path -Destination $record.target_path -ExpectedHash $record.preimage_sha256 -TransactionId $Journal.transaction_id -LastWriteUtc $record.source_last_write_utc
        }
        $record.restore_state = 'restored'
        $Journal.events += "restore-marker:$($record.side)"
        $Journal.last_completed_step = "restore-marker:$($record.side)"
        Save-MixedRepairJournal -JournalPath $JournalPath -Journal $Journal
    }
    Assert-MixedGuardsUnchanged -Inputs $Inputs -Journal $Journal
    $restored = Get-MixedSnapshotFromJournal -Inputs $Inputs -Journal $Journal
    if ($restored.software_canonical -cne $Journal.source_manifest.software_canonical -or
        $restored.evidence_canonical -cne $Journal.source_manifest.evidence_canonical) {
        throw '[UPGRADE_MIXED_ROLLBACK_FAIL] Full mixed source state ID was not restored.'
    }
    $Journal.failed_file = $null
    $Journal.state = 'rolled_back'
    $Journal.events += 'rolled_back'
    $Journal.last_completed_step = 'rolled_back'
    Save-MixedRepairJournal -JournalPath $JournalPath -Journal $Journal
    return $Journal
}

function Invoke-MixedRepairMode {
    param([Parameter(Mandatory = $true)]$Inputs)
    $journalPath = Join-Path $Inputs.TransactionRoot 'transaction-journal.json'
    if ($IsolatedAction -eq 'Rollback') {
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            throw '[UPGRADE_MIXED_TRANSACTION_FAIL] Explicit rollback requires an existing mixed repair journal.'
        }
        $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return Invoke-MixedRepairRollback -Inputs $Inputs -Journal $journal -JournalPath $journalPath
    }
    if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        throw '[UPGRADE_MIXED_TRANSACTION_FAIL] Apply refuses an existing mixed repair journal.'
    }
    return Invoke-MixedRepairApply -Inputs $Inputs -JournalPath $journalPath
}

# PrepareFormal and formal-apply validation/fixture-drill details stay in dedicated helpers; this file keeps only dispatch and exit mapping.
. (Join-Path $ScriptRoot 'upgrade_formal_prepare.ps1')
. (Join-Path $ScriptRoot 'upgrade_formal_apply.ps1')

$script:UpgradeExitCode = 0

function Invoke-UpgradeMain {
    $inputs = $null
    try {
        $inputs = Resolve-UpgradeInputs
        Assert-UpgradePreflight -Inputs $inputs
        if ($inputs.Mode -eq 'PreflightFormal') {
            $result = Invoke-FormalPreflightMode -Inputs $inputs
            $result | ConvertTo-Json -Depth 12 -Compress
            $script:UpgradeExitCode = if ($result.safe_to_upgrade) { 0 } else { 2 }
            return
        }
        if ($inputs.Mode -eq 'PrepareFormal') {
            $result = Invoke-FormalPrepareMode -Inputs $inputs
            $result | ConvertTo-Json -Depth 20 -Compress
            $script:UpgradeExitCode = 0
            return
        }
        if ($inputs.Mode -eq 'ValidateFormalApply') {
            $result = Invoke-FormalApplyValidationMode -Inputs $inputs
            $result | ConvertTo-Json -Depth 20 -Compress
            $script:UpgradeExitCode = if ($result.eligible) { 0 } else { 7 }
            return
        }
        if ($inputs.Mode -eq 'ApplyFormalFixture') {
            $result = Invoke-FormalApplyFixtureMode -Inputs $inputs
            $result | ConvertTo-Json -Depth 30 -Compress
            $script:UpgradeExitCode = if ($result.result -in @('installed_pending_acceptance', 'rolled_back')) { 0 } else { 8 }
            return
        }
        if ($inputs.Mode -eq 'RecoverFormalFixture') {
            $result = Invoke-FormalApplyFixtureRecoveryMode -Inputs $inputs
            $result | ConvertTo-Json -Depth 30 -Compress
            $script:UpgradeExitCode = if ($result.result -eq 'rolled_back') { 0 } else { 8 }
            return
        }
        if ($inputs.Mode -eq 'ApplyFormalInternal') {
            $result = Invoke-FormalApplyInternalMode -Inputs $inputs
            $result | ConvertTo-Json -Depth 30 -Compress
            $script:UpgradeExitCode = if ($result.result -in @('installed_pending_acceptance', 'rolled_back')) { 0 } else { 8 }
            return
        }
        if ($inputs.Mode -eq 'RecoverFormalInternal') {
            $result = Invoke-FormalApplyInternalRecoveryMode -Inputs $inputs
            $result | ConvertTo-Json -Depth 30 -Compress
            $script:UpgradeExitCode = if ($result.result -eq 'rolled_back') { 0 } else { 8 }
            return
        }
        if ($inputs.Mode -eq 'RepairMixedIsolated') {
            $result = Invoke-MixedRepairMode -Inputs $inputs
            $result | ConvertTo-Json -Depth 20
            return
        }
        if ($inputs.Mode -eq 'ApplyIsolated' -and $IsolatedAction -eq 'Rollback') {
            $result = Invoke-ApplyIsolatedMode -Inputs $inputs -Plan $null
            $result | ConvertTo-Json -Depth 12
            return
        }
        $plan = New-UpgradePlan -Inputs $inputs

        if ($inputs.Mode -eq 'DryRun') {
            $plan | ConvertTo-Json -Depth 12
            return
        }

        if ($inputs.Mode -eq 'ApplyIsolated') {
            $result = Invoke-ApplyIsolatedMode -Inputs $inputs -Plan $plan
            $result | ConvertTo-Json -Depth 12
            return
        }

        Invoke-IsolatedStage -Inputs $inputs -Plan $plan
        Get-Content -LiteralPath (Join-Path $inputs.StagingRoot 'upgrade-plan.json') -Raw
        return
    }
    catch {
        if ($Mode -eq 'PreflightFormal') {
            $failureMessage = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
            if ($null -eq $inputs) {
                $inputs = [pscustomobject]@{ FrontendTarget = $FrontendTarget; BackendTarget = $BackendTarget }
            }
            $failureResult = New-FormalPreflightResult -Inputs $inputs
            Add-FormalPreflightFailure -Result $failureResult -Tag '[UPGRADE_PREFLIGHT_FAIL]' -CheckId 'preflight' -Message $failureMessage
            Add-FormalPreflightCheck -Result $failureResult -Id 'preflight' -Status 'indeterminate' -TruthSource 'PreflightFormal hard boundary and read prerequisites' -Reason $failureMessage
            $failureResult | ConvertTo-Json -Depth 12 -Compress
            [Console]::Error.WriteLine("[UPGRADE_PREFLIGHT_FAIL] $failureMessage")
            $script:UpgradeExitCode = 2
            return
        }
        if ($Mode -eq 'PrepareFormal') {
            $failureMessage = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
            $failureResult = New-FormalPrepareFailureResult -Message $failureMessage
            $failureResult | ConvertTo-Json -Depth 12 -Compress
            [Console]::Error.WriteLine("[UPGRADE_PREPARE_FAIL] $failureMessage")
            $script:UpgradeExitCode = 6
            return
        }
        if ($Mode -eq 'ValidateFormalApply') {
            $failureMessage = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
            $failureResult = New-FormalApplyValidationFailureResult -Inputs $inputs -Message $failureMessage
            $failureResult | ConvertTo-Json -Depth 20 -Compress
            [Console]::Error.WriteLine("[UPGRADE_APPLY_VALIDATION_FAIL] $failureMessage")
            $script:UpgradeExitCode = 7
            return
        }
        if ($Mode -in @('ApplyFormalFixture', 'RecoverFormalFixture', 'ApplyFormalInternal', 'RecoverFormalInternal')) {
            $failureMessage = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
            $failureResult = New-FormalApplyFixtureFailureResult -Inputs $inputs -Message $failureMessage
            $failureResult | ConvertTo-Json -Depth 20 -Compress
            [Console]::Error.WriteLine("[UPGRADE_APPLY_EXECUTION_FAIL] $failureMessage")
            $script:UpgradeExitCode = 8
            return
        }
        $tag = if ($Mode -eq 'Stage') { 'UPGRADE_STAGE_FAIL' } elseif ($Mode -eq 'ApplyIsolated') { 'UPGRADE_ISOLATED_FAIL' } elseif ($Mode -eq 'RepairMixedIsolated') { 'UPGRADE_MIXED_FAIL' } else { 'UPGRADE_PREFLIGHT_FAIL' }
        [Console]::Error.WriteLine("[$tag] $($_.Exception.Message)")
        $script:UpgradeExitCode = if ($Mode -eq 'Stage') { 3 } elseif ($Mode -eq 'ApplyIsolated') { 4 } elseif ($Mode -eq 'RepairMixedIsolated') { 5 } else { 2 }
        return
    }
}

Invoke-UpgradeMain
exit $script:UpgradeExitCode
