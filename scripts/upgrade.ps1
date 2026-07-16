[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Stage', 'ApplyIsolated', 'PreflightFormal')]
    [string]$Mode = 'DryRun',

    [string]$StagingRoot,

    [string]$IsolationRoot,

    [string]$PreflightObservationPath,

    [ValidateSet('Apply', 'Rollback')]
    [string]$IsolatedAction = 'Apply',

    [ValidateSet('None', 'DirtySource', 'FrontendApply', 'BackendApply', 'Version', 'Smoke', 'Rollback')]
    [string]$FailureInjection = 'None',

    [string]$FrontendTarget = (Join-Path $env:LOCALAPPDATA 'LaplaceSentry'),

    [string]$BackendTarget = '\\wsl.localhost\Ubuntu\home\serpal\.laplace_sentry_backend',

    [string]$BuildVersion
)

<#
.SYNOPSIS
Builds a safe Laplace Sentry upgrade plan or an isolated staging package.

.DESCRIPTION
Purpose: provide the policy-bearing upgrade plan, isolated transaction proof, and formal read-only preflight.
Inputs: repo sources, target paths, mode, staging/isolation roots, optional preflight observation, isolated action, failure injection, version override.
Outputs: JSON plan/result on stdout; Stage writes package/backup/manifest; ApplyIsolated writes a fake-target transaction journal.
SSOT Output: stdout JSON in DryRun/PreflightFormal, upgrade-plan.json in Stage, transaction-journal.json in ApplyIsolated.
Exit codes: 0 success, 2 preflight/argument failure, 3 isolated staging failure, 4 isolated apply/rollback failure.
Idempotency: DryRun and PreflightFormal are read-only. Stage requires an empty/nonexistent StagingRoot. ApplyIsolated refuses an existing transaction and only permits explicit rollback.
Side effects: Stage and ApplyIsolated write only inside their verified TEMP isolation boundary; formal targets and real processes are never touched.
#>

# 這支腳本在做什麼：建立安全升級計畫、只讀檢查正式環境，並用 TEMP 假目標證明 apply／rollback transaction。
# 這支腳本不做什麼：不提供正式 apply 入口，不啟停真實程序，不更新正式 runtime 或正式版本。
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

    if ($Inputs.Mode -eq 'PreflightFormal') {
        Assert-FormalPreflightBoundary -Inputs $Inputs
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
        $tag = if ($Mode -eq 'Stage') { 'UPGRADE_STAGE_FAIL' } elseif ($Mode -eq 'ApplyIsolated') { 'UPGRADE_ISOLATED_FAIL' } else { 'UPGRADE_PREFLIGHT_FAIL' }
        [Console]::Error.WriteLine("[$tag] $($_.Exception.Message)")
        $script:UpgradeExitCode = if ($Mode -eq 'Stage') { 3 } elseif ($Mode -eq 'ApplyIsolated') { 4 } else { 2 }
        return
    }
}

Invoke-UpgradeMain
exit $script:UpgradeExitCode
