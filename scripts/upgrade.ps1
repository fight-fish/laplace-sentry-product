[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Stage')]
    [string]$Mode = 'DryRun',

    [string]$StagingRoot,

    [string]$FrontendTarget = (Join-Path $env:LOCALAPPDATA 'LaplaceSentry'),

    [string]$BackendTarget = '\\wsl.localhost\Ubuntu\home\serpal\.laplace_sentry_backend',

    [string]$BuildVersion
)

<#
.SYNOPSIS
Builds a safe Laplace Sentry upgrade plan or an isolated staging package.

.DESCRIPTION
Purpose: provide the policy-bearing implementation behind upgrade.bat.
Inputs: repo sources, read-only target paths, mode, staging root, version override.
Outputs: JSON plan on stdout; Stage also writes package, backup, and manifest under StagingRoot.
SSOT Output: upgrade-plan.json in Stage mode; stdout JSON in DryRun mode.
Exit codes: 0 success, 2 preflight/argument failure, 3 isolated staging failure.
Idempotency: DryRun is read-only. Stage requires an empty/nonexistent StagingRoot.
Side effects: Stage writes only beneath StagingRoot; formal targets are never written.
#>

# 這支腳本在做什麼：建立安全升級計畫，並可在隔離 staging 產生升級包與備份演練。
# 這支腳本不做什麼：本階段沒有 apply、process stop、正式 version 更新或正式 rollback 能力。
# 常改區塊：allowlist、保留資料清單、smoke 計畫。
# 不要亂動的區塊：正式目標唯讀、Backend/data 永不進 package、StageRoot 邊界檢查。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$FrontendSource = Join-Path $RepoRoot 'Frontend'
$BackendSource = Join-Path $RepoRoot 'Backend'

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
    }
}

function Assert-UpgradePreflight {
    param([Parameter(Mandatory = $true)]$Inputs)

    foreach ($requiredPath in @($FrontendSource, $BackendSource)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Container)) {
            throw "[UPGRADE_PREFLIGHT_FAIL] Missing source directory: $requiredPath"
        }
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

$script:UpgradeExitCode = 0

function Invoke-UpgradeMain {
    try {
        $inputs = Resolve-UpgradeInputs
        Assert-UpgradePreflight -Inputs $inputs
        $plan = New-UpgradePlan -Inputs $inputs

        if ($inputs.Mode -eq 'DryRun') {
            $plan | ConvertTo-Json -Depth 12
            return
        }

        Invoke-IsolatedStage -Inputs $inputs -Plan $plan
        Get-Content -LiteralPath (Join-Path $inputs.StagingRoot 'upgrade-plan.json') -Raw
        return
    }
    catch {
        $tag = if ($Mode -eq 'Stage') { 'UPGRADE_STAGE_FAIL' } else { 'UPGRADE_PREFLIGHT_FAIL' }
        [Console]::Error.WriteLine("[$tag] $($_.Exception.Message)")
        $script:UpgradeExitCode = if ($Mode -eq 'Stage') { 3 } else { 2 }
        return
    }
}

Invoke-UpgradeMain
exit $script:UpgradeExitCode
