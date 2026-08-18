<#
.SYNOPSIS
建立正式修復前的完整證據交易，但不套用任何檔案。

.DESCRIPTION
Purpose: validate the exact ruled mixed source, then seal a full preimage, exact Git-object package, canonical manifests, and a durable prepare journal.
Inputs: normalized upgrade inputs; fixed formal targets for live mode, or complete isolated TEMP targets plus observation JSON for fixture mode.
Outputs: one transaction directory containing preimage/, package/, three manifests, and transaction-journal.json.
SSOT Output: transaction-journal.json; stdout is derived from the same journal fields.
Exit codes: the caller maps prepared/already_prepared to 0 and every rejection, recovery gate, or prepare failure to 6.
SKIP conditions: one intact, identical prepared_pending_apply transaction returns already_prepared without writing.
FAIL conditions: boundary, ACL/owner, space, runtime, exact source, evidence, reentry, or durability checks fail.
Order-sensitive checks: every live/source gate and already-prepared decision occurs before a new transaction directory is created.
Side effects: writes only below the verified transaction parent; never writes formal targets, stops processes, cleans registry, applies, repairs, or rolls back.
#>

# 這支腳本在做什麼：正式修復前先留下完整原貌、待套用資料與可驗證交易紀錄，成功後停在等待套用。
# 這支腳本不做什麼：不套用、不修復、不回退、不啟停程序、不清 registry，也不碰正式目標內容。
# 常改區塊：prepare 的硬檢查、manifest 欄位、交易重入與 TEMP 故障注入。
# 不要亂動的區塊：固定正式路徑、exact mixed state、0 正式寫入、durable journal 與 evidence hash sealing。

Set-StrictMode -Version Latest

$FormalPrepareSchema = 'laplace-formal-prepare-v1'
# 決策 331 固定的真實三段來源鏈與未來唯一 merge shape。
$FormalPrepareOriginMainHead = '08bb6641ac042c6ce20ec92501f6814fe9f22fac'
$FormalPrepareExistingCheckpointHead = 'bf8f57bf7e1d31d3a708ba80ef0316faef8ebea9'
$FormalPreparePreflightCheckpointHead = 'c7aa16cac8d8843545198d66faa69d009dd9127e'
$FormalPrepareExistingCheckpointPaths = @(
    'scripts/upgrade_formal_prepare.ps1',
    'tests/upgrade_formal_prepare_smoke.ps1',
    'scripts/upgrade.ps1',
    'tests/upgrade_mixed_repair_smoke.ps1',
    'tests/upgrade_formal_apply_smoke.ps1',
    'tests/test_frontend_lazy_tree_contract.py'
)
$FormalPreparePreflightCheckpointPaths = @(
    'scripts/upgrade.ps1',
    'tests/upgrade_formal_preflight_smoke.ps1',
    'tests/run_upgrade_quick_gate.ps1',
    'scripts/upgrade_formal_prepare.ps1',
    'tests/upgrade_formal_prepare_smoke.ps1'
)
$FormalPrepareFollowUpPaths = @(
    'scripts/upgrade_formal_prepare.ps1',
    'tests/upgrade_formal_prepare_smoke.ps1',
    'tests/run_upgrade_quick_gate.ps1',
    'tests/upgrade_mixed_repair_smoke.ps1',
    'tests/upgrade_formal_apply_smoke.ps1'
)
$FormalPrepareCumulativePaths = @($FormalPrepareExistingCheckpointPaths + $FormalPreparePreflightCheckpointPaths + $FormalPrepareFollowUpPaths | Sort-Object -Unique)
$FormalPrepareMergedMainHead = '8baf0d70d0b76069d12bf70e1342aca3d08432ac'
$FormalPrepareApprovedWorkingBranch = 's/S-02-03b/exact-mixed-live-source-baseline'
$FormalPrepareCurrentCutPaths = @(
    'scripts/upgrade.ps1',
    'scripts/upgrade_formal_prepare.ps1',
    'tests/run_upgrade_quick_gate.ps1',
    'tests/upgrade_formal_apply_smoke.ps1',
    'tests/upgrade_formal_preflight_smoke.ps1',
    'tests/upgrade_formal_prepare_smoke.ps1',
    'tests/upgrade_mixed_repair_smoke.ps1'
)
$FormalPrepareFixtureDirtyPaths = @($FormalPrepareCurrentCutPaths)
$FormalUpgradeTargetCommit = '08bb6641ac042c6ce20ec92501f6814fe9f22fac'
$FormalPrepareTransactionsParent = Join-Path $env:LOCALAPPDATA 'LaplaceSentryUpgrade\transactions'
$FormalPrepareJournalReserveBytes = [int64](1MB)
$FormalPrepareSafetyMarginBytes = [int64](64MB)
$script:FormalPrepareFailureJournal = $null

# =========================
# 輸入與路徑邊界
# =========================

function Test-FormalPrepareFixtureMode {
    param([Parameter(Mandatory = $true)]$Inputs)
    return [bool]($Inputs.IsolationRoot -or $Inputs.TransactionRoot -or $Inputs.PreflightObservationPath)
}

function Get-FormalPrepareTransactionParent {
    param([Parameter(Mandatory = $true)]$Inputs)
    if (Test-FormalPrepareFixtureMode -Inputs $Inputs) { return Get-NormalizedFullPath $Inputs.TransactionRoot }
    return Get-NormalizedFullPath $FormalPrepareTransactionsParent
}

function Assert-FormalPrepareNoReparse {
    param([Parameter(Mandatory = $true)][string]$Path)
    $cursor = Get-NormalizedFullPath $Path
    while (-not (Test-Path -LiteralPath $cursor)) {
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    while ($cursor -and (Test-Path -LiteralPath $cursor)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "[UPGRADE_PREPARE_BOUNDARY_FAIL] Reparse/junction ambiguity is forbidden: $cursor"
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-FormalPrepareBoundary {
    param([Parameter(Mandatory = $true)]$Inputs)
    $fixtureMode = Test-FormalPrepareFixtureMode -Inputs $Inputs
    if (-not $fixtureMode) {
        if (-not (Test-PathsEqual -First $Inputs.FrontendTarget -Second $FormalFrontendTarget) -or
            -not (Test-PathsEqual -First $Inputs.BackendTarget -Second $FormalBackendTarget)) {
            throw '[UPGRADE_PREPARE_BOUNDARY_FAIL] Live PrepareFormal only accepts the two fixed formal targets.'
        }
        $parent = Get-FormalPrepareTransactionParent -Inputs $Inputs
        if ($parent.StartsWith('\\')) { throw '[UPGRADE_PREPARE_BOUNDARY_FAIL] The formal transaction parent must not be UNC.' }
        foreach ($target in @($Inputs.FrontendTarget, $Inputs.BackendTarget)) {
            if (Test-PathsOverlap -First $parent -Second $target) {
                throw '[UPGRADE_PREPARE_BOUNDARY_FAIL] The formal transaction parent overlaps a formal target.'
            }
        }
        Assert-FormalPrepareNoReparse -Path $parent
        return
    }

    if (-not $Inputs.IsolationRoot -or -not $Inputs.TransactionRoot -or -not $Inputs.PreflightObservationPath) {
        throw '[UPGRADE_PREPARE_BOUNDARY_FAIL] Fixture PrepareFormal requires IsolationRoot, TransactionRoot parent, and PreflightObservationPath.'
    }
    if (-not (Test-StrictPathInside -Candidate $Inputs.IsolationRoot -Container $TempRoot) -or
        -not (Test-Path -LiteralPath $Inputs.IsolationRoot -PathType Container)) {
        throw '[UPGRADE_PREPARE_BOUNDARY_FAIL] Fixture IsolationRoot must be an existing strict child of system TEMP.'
    }
    $peers = @(
        [pscustomobject]@{ Label = 'FrontendTarget'; Path = $Inputs.FrontendTarget },
        [pscustomobject]@{ Label = 'BackendTarget'; Path = $Inputs.BackendTarget },
        [pscustomobject]@{ Label = 'TransactionRoot'; Path = $Inputs.TransactionRoot },
        [pscustomobject]@{ Label = 'PreflightObservationPath'; Path = $Inputs.PreflightObservationPath }
    )
    foreach ($peer in $peers) {
        if (-not (Test-StrictPathInside -Candidate $peer.Path -Container $Inputs.IsolationRoot)) {
            throw "[UPGRADE_PREPARE_BOUNDARY_FAIL] Fixture $($peer.Label) escaped IsolationRoot: $($peer.Path)"
        }
        foreach ($forbidden in @($RepoRoot, $FormalFrontendTarget, $FormalBackendTarget, $FormalPrepareTransactionsParent)) {
            if (Test-PathsOverlap -First $peer.Path -Second $forbidden) {
                throw "[UPGRADE_PREPARE_BOUNDARY_FAIL] Fixture $($peer.Label) overlaps a repository or formal path."
            }
        }
        Assert-FormalPrepareNoReparse -Path $peer.Path
    }
    for ($first = 0; $first -lt $peers.Count; $first++) {
        for ($second = $first + 1; $second -lt $peers.Count; $second++) {
            if (Test-PathsOverlap -First $peers[$first].Path -Second $peers[$second].Path) {
                throw "[UPGRADE_PREPARE_BOUNDARY_FAIL] Fixture $($peers[$first].Label) and $($peers[$second].Label) must be mutually exclusive."
            }
        }
    }
    if ($Inputs.BackendTarget -match '(?i)(^|[\\/])\.laplace_sentry_backend([\\/]|$)') {
        throw '[UPGRADE_PREPARE_BOUNDARY_FAIL] A formal-runtime-shaped backend fixture is forbidden.'
    }
    foreach ($target in @($Inputs.FrontendTarget, $Inputs.BackendTarget)) {
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            throw "[UPGRADE_PREPARE_BOUNDARY_FAIL] Fixture target is missing: $target"
        }
    }
    if (-not (Test-Path -LiteralPath $Inputs.PreflightObservationPath -PathType Leaf)) {
        throw '[UPGRADE_PREPARE_BOUNDARY_FAIL] Fixture observation JSON is missing.'
    }
}

# =========================
# 前置檢查與 canonical 證據
# =========================

# checkpoint 相容只接受「明確核准錨點本身」或「核准錨點的單一直接子提交且改檔集合完全一致」。
# 合併後主線只接受決策 289 指定的唯一合併形狀：舊主線 + 核准來源、精確檔案集合、精確 tree。
function Test-FormalPrepareExactPathSet {
    param(
        [string[]]$ExpectedPaths,
        [string[]]$ActualPaths
    )

    $expected = @($ExpectedPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $actual = @($ActualPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    if ($expected.Count -ne $actual.Count) {
        return $false
    }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($expected[$i] -ne $actual[$i]) {
            return $false
        }
    }
    return $true
}

function Test-FormalPrepareSourceChainShape {
    param(
        [string]$ExistingParent,
        [string[]]$ExistingPaths,
        [string]$PreflightParent,
        [string[]]$PreflightPaths,
        [string]$FollowUpParent = '',
        [string[]]$FollowUpPaths = @(),
        [bool]$RequireFollowUp = $false
    )
    if ($ExistingParent -ne $FormalPrepareOriginMainHead -or
        -not (Test-FormalPrepareExactPathSet -ExpectedPaths $FormalPrepareExistingCheckpointPaths -ActualPaths $ExistingPaths) -or
        $PreflightParent -ne $FormalPrepareExistingCheckpointHead -or
        -not (Test-FormalPrepareExactPathSet -ExpectedPaths $FormalPreparePreflightCheckpointPaths -ActualPaths $PreflightPaths)) { return $false }
    if (-not $RequireFollowUp) { return $true }
    return ($FollowUpParent -eq $FormalPreparePreflightCheckpointHead -and
        (Test-FormalPrepareExactPathSet -ExpectedPaths $FormalPrepareFollowUpPaths -ActualPaths $FollowUpPaths))
}

function Test-FormalPrepareApprovedMergeShape {
    param(
        [string[]]$ParentHeads,
        [string[]]$ChangedPaths,
        [string]$CurrentTree,
        [string]$ApprovedSourceTree,
        [bool]$SourceChainValid
    )
    $parents = @($ParentHeads | Where-Object { $_ })
    return ($SourceChainValid -and $parents.Count -eq 2 -and
        $parents[0] -eq $FormalPrepareOriginMainHead -and
        (Test-FormalPrepareExactPathSet -ExpectedPaths $FormalPrepareCumulativePaths -ActualPaths $ChangedPaths) -and
        $CurrentTree -and $CurrentTree -eq $ApprovedSourceTree)
}

function Test-FormalPrepareCurrentSourceCheckpointShape {
    param(
        [string[]]$ParentHeads,
        [string[]]$ChangedPaths
    )
    $parents = @($ParentHeads | Where-Object { $_ })
    return ($parents.Count -eq 1 -and
        $parents[0] -eq $FormalPrepareMergedMainHead -and
        (Test-FormalPrepareExactPathSet -ExpectedPaths $FormalPrepareCurrentCutPaths -ActualPaths $ChangedPaths))
}

function Test-FormalPrepareCurrentMergeShape {
    param(
        [string[]]$ParentHeads,
        [string[]]$ChangedPaths,
        [string]$CurrentTree,
        [string]$ApprovedSourceTree,
        [bool]$SourceCheckpointValid
    )
    $parents = @($ParentHeads | Where-Object { $_ })
    return ($SourceCheckpointValid -and $parents.Count -eq 2 -and
        $parents[0] -eq $FormalPrepareMergedMainHead -and
        $CurrentTree -and $CurrentTree -eq $ApprovedSourceTree -and
        (Test-FormalPrepareExactPathSet -ExpectedPaths $FormalPrepareCurrentCutPaths -ActualPaths $ChangedPaths))
}

function Get-FormalPrepareCommitShape {
    param([Parameter(Mandatory = $true)][string]$Commit)
    $identity = ((Get-GitOutput -Arguments @('rev-list', '--parents', '-n', '1', $Commit) | Select-Object -First 1).Trim()) -split '\s+'
    if ($identity.Count -lt 2) { throw "unexpected_parent_shape:$Commit" }
    $parents = @($identity[1..($identity.Count - 1)])
    return [pscustomobject]@{
        Parents = $parents
        Paths = @(Get-GitOutput -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', $parents[0], $Commit) | ForEach-Object { ([string]$_).Replace('\', '/') })
        Tree = (Get-GitOutput -Arguments @('show', '-s', '--format=%T', $Commit) | Select-Object -First 1).Trim()
    }
}

function Test-FormalPrepareRealSourceChain {
    param([Parameter(Mandatory = $true)][string]$SourceHead, [bool]$RequireFollowUp)
    $existing = Get-FormalPrepareCommitShape -Commit $FormalPrepareExistingCheckpointHead
    $preflight = Get-FormalPrepareCommitShape -Commit $FormalPreparePreflightCheckpointHead
    $followUpParent = ''; $followUpPaths = @()
    if ($RequireFollowUp) {
        $followUp = Get-FormalPrepareCommitShape -Commit $SourceHead
        if ($followUp.Parents.Count -ne 1) { return $false }
        $followUpParent = $followUp.Parents[0]; $followUpPaths = $followUp.Paths
    }
    if ($existing.Parents.Count -ne 1 -or $preflight.Parents.Count -ne 1) { return $false }
    return Test-FormalPrepareSourceChainShape -ExistingParent $existing.Parents[0] -ExistingPaths $existing.Paths -PreflightParent $preflight.Parents[0] -PreflightPaths $preflight.Paths -FollowUpParent $followUpParent -FollowUpPaths $followUpPaths -RequireFollowUp $RequireFollowUp
}

function Assert-FormalPrepareCheckpointBasis {
    param([Parameter(Mandatory = $true)][string]$CurrentHead, [string]$FailureTag = 'UPGRADE_PREPARE_BASIS_FAIL')
    if (-not $CurrentHead) { throw "[$FailureTag] unable_to_resolve_head" }
    try {
        if ($CurrentHead -eq $FormalPreparePreflightCheckpointHead) {
            if (Test-FormalPrepareRealSourceChain -SourceHead $CurrentHead -RequireFollowUp $false) { return 'checkpoint' }
        }
        else {
            $current = Get-FormalPrepareCommitShape -Commit $CurrentHead
            if ($current.Parents.Count -eq 1 -and $current.Parents[0] -eq $FormalPreparePreflightCheckpointHead -and
                (Test-FormalPrepareRealSourceChain -SourceHead $CurrentHead -RequireFollowUp $true)) { return 'checkpoint' }
            if ($current.Parents.Count -eq 2) {
                $source = $current.Parents[1]
                $sourceTree = (Get-GitOutput -Arguments @('show', '-s', '--format=%T', $source) | Select-Object -First 1).Trim()
                $cumulative = @(Get-GitOutput -Arguments @('diff', '--name-only', $FormalPrepareOriginMainHead, $CurrentHead) | ForEach-Object { ([string]$_).Replace('\', '/') })
                $chainValid = Test-FormalPrepareRealSourceChain -SourceHead $source -RequireFollowUp $true
                if (Test-FormalPrepareApprovedMergeShape -ParentHeads $current.Parents -ChangedPaths $cumulative -CurrentTree $current.Tree -ApprovedSourceTree $sourceTree -SourceChainValid $chainValid) {
                    if ($CurrentHead -eq $FormalPrepareMergedMainHead) { return 'merged-main' }
                    return 'checkpoint'
                }
            }
            if ($current.Parents.Count -eq 1 -and
                (Test-FormalPrepareCurrentSourceCheckpointShape -ParentHeads $current.Parents -ChangedPaths $current.Paths) -and
                (Assert-FormalPrepareCheckpointBasis -CurrentHead $FormalPrepareMergedMainHead -FailureTag $FailureTag) -eq 'merged-main') {
                return 'source-checkpoint'
            }
            if ($current.Parents.Count -eq 2) {
                $source = $current.Parents[1]
                $sourceShape = Get-FormalPrepareCommitShape -Commit $source
                $sourceValid = Test-FormalPrepareCurrentSourceCheckpointShape -ParentHeads $sourceShape.Parents -ChangedPaths $sourceShape.Paths
                $sourceTree = $sourceShape.Tree
                $changed = @(Get-GitOutput -Arguments @('diff', '--name-only', $FormalPrepareMergedMainHead, $CurrentHead) | ForEach-Object { ([string]$_).Replace('\', '/') })
                if ((Assert-FormalPrepareCheckpointBasis -CurrentHead $FormalPrepareMergedMainHead -FailureTag $FailureTag) -eq 'merged-main' -and
                    (Test-FormalPrepareCurrentMergeShape -ParentHeads $current.Parents -ChangedPaths $changed -CurrentTree $current.Tree -ApprovedSourceTree $sourceTree -SourceCheckpointValid $sourceValid)) {
                    return 'future-merge'
                }
            }
        }
    } catch { throw "[$FailureTag] checkpoint_basis_unverified: $($_.Exception.Message)" }
    throw "[$FailureTag] Expected the ruled legacy chain, merged main 8baf0d70, its exact seven-path direct child, or the exact [8baf0d70, source checkpoint] merge; got $CurrentHead."
}

function Assert-FormalPrepareRepoState {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentHead,
        [Parameter(Mandatory = $true)][string]$OriginMain,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Staged,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Dirty,
        [bool]$FixtureMode,
        [string]$BasisKind = ''
    )
    if (-not $BasisKind) { $BasisKind = Assert-FormalPrepareCheckpointBasis -CurrentHead $CurrentHead }
    if (-not $FixtureMode -and -not $OriginMain.Equals($CurrentHead, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '[UPGRADE_PREPARE_BASIS_FAIL] Current structurally approved HEAD differs from origin/main.'
    }
    if ($FixtureMode -and $BasisKind -in @('merged-main', 'source-checkpoint') -and
        -not $OriginMain.Equals($FormalPrepareMergedMainHead, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '[UPGRADE_PREPARE_BASIS_FAIL] Fixture origin/main differs from the fixed merged-main anchor.'
    }
    if ($Staged.Count -gt 0) {
        throw '[UPGRADE_PREPARE_BASIS_FAIL] Staged files exist.'
    }
    $generalAllowed = @('.gitignore', 'Frontend/src/backend/adapter.py')
    $normalizedDirty = @($Dirty | ForEach-Object { ([string]$_).Replace('\', '/') })
    $unexpected = @($normalizedDirty | Where-Object { $_ -notin $generalAllowed -and $_ -notin $FormalPrepareFixtureDirtyPaths })
    if ($unexpected.Count -gt 0) {
        throw "[UPGRADE_PREPARE_BASIS_FAIL] Unexpected working-tree path(s): $($unexpected -join ', ')"
    }
    $cutDirty = @($normalizedDirty | Where-Object { $_ -in $FormalPrepareFixtureDirtyPaths })
    if (-not $FixtureMode -and $cutDirty.Count -gt 0) {
        throw '[UPGRADE_PREPARE_BASIS_FAIL] Live mode does not accept current-cut working-tree changes.'
    }
    if ($FixtureMode -and $BasisKind -eq 'merged-main' -and
        -not (Test-FormalPrepareExactPathSet -ExpectedPaths $FormalPrepareFixtureDirtyPaths -ActualPaths $cutDirty)) {
        throw '[UPGRADE_PREPARE_BASIS_FAIL] Pre-checkpoint fixture requires the exact seven-path dirty set.'
    }
    if ($FixtureMode -and $BasisKind -ne 'merged-main' -and $cutDirty.Count -gt 0) {
        throw '[UPGRADE_PREPARE_BASIS_FAIL] Checkpoint or merge fixture must not retain current-cut dirty paths.'
    }
}

function Assert-FormalPrepareMainBranch {
    param([AllowNull()][string]$BranchOutput, [bool]$FixtureMode)
    $branch = ([string]$BranchOutput).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw '[UPGRADE_PREPARE_BASIS_FAIL] Expected branch main, got detached HEAD.'
    }
    $allowed = if ($FixtureMode) { @('main', $FormalPrepareApprovedWorkingBranch) } else { @('main') }
    if ($branch -notin $allowed) {
        throw "[UPGRADE_PREPARE_BASIS_FAIL] Expected branch $($allowed -join ' or '), got $branch."
    }
    return $branch
}

function Assert-FormalPrepareRepoBasis {
    param([bool]$FixtureMode)
    $branch = Assert-FormalPrepareMainBranch -BranchOutput (Get-GitOutput -Arguments @('branch', '--show-current') | Select-Object -First 1) -FixtureMode $FixtureMode

    $head = Get-HeadCommit
    $originMain = (Get-GitOutput -Arguments @('rev-parse', 'origin/main') | Select-Object -First 1).Trim()
    $staged = @(Get-GitOutput -Arguments @('diff', '--cached', '--name-only'))
    $basisKind = Assert-FormalPrepareCheckpointBasis -CurrentHead $head
    if ($FixtureMode -and $basisKind -in @('merged-main', 'source-checkpoint') -and $branch -ne $FormalPrepareApprovedWorkingBranch) {
        throw "[UPGRADE_PREPARE_BASIS_FAIL] $basisKind fixture requires branch $FormalPrepareApprovedWorkingBranch."
    }
    $dirty = @(Get-GitOutput -Arguments @('status', '--porcelain=v1', '--untracked-files=all') | ForEach-Object {
        if ($_.Length -ge 4) { $_.Substring(3).Replace('\\', '/') } else { $_ }
    })
    Assert-FormalPrepareRepoState -CurrentHead $head -OriginMain $originMain -Staged $staged -Dirty $dirty -FixtureMode $FixtureMode -BasisKind $basisKind
    $plan = New-UpgradePlan -Inputs ([pscustomobject]@{
        Mode = 'PrepareFormal'
        BuildVersion = $FormalUpgradeTargetCommit.Substring(0, 7)
        Timestamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
        StagingRoot = Join-Path $TempRoot 'LaplaceSentryPreparePlan-ReadOnly'
        FrontendTarget = $FormalFrontendTarget
        BackendTarget = $FormalBackendTarget
    })
    Assert-ManagedSourcesMatchHead -Plan $plan
}
function Get-FormalPrepareObservation {
    param([Parameter(Mandatory = $true)]$Inputs)
    if (Test-FormalPrepareFixtureMode -Inputs $Inputs) {
        $observation = Read-PreflightFixtureObservation -Path $Inputs.PreflightObservationPath
        foreach ($required in @('transaction_acl_ok', 'transaction_owner_ok', 'free_bytes', 'fixture_backend_mode', 'fixture_backend_uid', 'fixture_backend_gid')) {
            if ($null -eq $observation.PSObject.Properties[$required]) {
                throw "[UPGRADE_PREPARE_FIXTURE_FAIL] Complete fixture observation is missing: $required"
            }
        }
        return $observation
    }
    return Get-LivePreflightObservation -Inputs $Inputs
}

function Assert-FormalPrepareObservationSafe {
    param([Parameter(Mandatory = $true)]$Observation)
    [void](Assert-MixedObservationSafe -Path $script:FormalPrepareObservationPath)
    foreach ($name in @('source_dirty', 'force_non_ancestor')) {
        if ([bool](Get-OptionalProperty -Object $Observation -Name $name -Default $false)) {
            throw "[UPGRADE_PREPARE_RUNTIME_FAIL] Observation rejected: $name"
        }
    }
    foreach ($name in @('tracked_deletions', 'requirements_changes', 'protected_unreadable', 'ambiguous_runtime')) {
        if (@(Get-OptionalProperty -Object $Observation -Name $name -Default @()).Count -gt 0) {
            throw "[UPGRADE_PREPARE_RUNTIME_FAIL] Observation rejected: $name"
        }
    }
}

function ConvertTo-FormalPrepareObservationRecord {
    param([Parameter(Mandatory = $true)]$Observation)
    $canonical = $Observation | ConvertTo-Json -Depth 12 -Compress
    return [pscustomobject]@{
        record_type = 'runtime_observation'
        side = 'Runtime'
        relative_path = 'observation.json'
        exists = $true
        length = [int64][System.Text.Encoding]::UTF8.GetByteCount($canonical)
        sha256 = Get-Utf8Sha256 $canonical
        last_write_utc = $null
    }
}

function Get-FormalPrepareSourceSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$Observation
    )
    $software = @()
    foreach ($record in $Layout) {
        $software += New-MixedFileRecord -RecordType $record.record_type -Side $record.side -RelativePath $record.relative_path -Path $record.target_path
    }
    $software += New-MixedFileRecord -RecordType 'marker' -Side 'Frontend' -RelativePath 'version.txt' -Path (Join-Path $Inputs.FrontendTarget 'version.txt')
    $software += New-MixedFileRecord -RecordType 'marker' -Side 'Backend' -RelativePath 'version.txt' -Path (Join-Path $Inputs.BackendTarget 'version.txt')
    $protected = @(
        (New-MixedFileRecord -RecordType 'protected' -Side 'Frontend' -RelativePath 'sentry_config.ini' -Path (Join-Path $Inputs.FrontendTarget 'sentry_config.ini')),
        (New-MixedFileRecord -RecordType 'protected' -Side 'Backend' -RelativePath 'data/projects.json' -Path (Join-Path $Inputs.BackendTarget 'data\projects.json'))
    )
    foreach ($record in $protected) {
        if (-not $record.exists) { throw "[UPGRADE_PREPARE_SOURCE_FAIL] Required protected file is missing: $($record.side)/$($record.relative_path)" }
    }
    $runtime = ConvertTo-FormalPrepareObservationRecord -Observation $Observation
    $targetRecords = @($software) + @($protected)
    $evidence = @($targetRecords) + @($runtime)
    $softwareState = Get-MixedStateId -Schema $FormalPrepareSchema -Records $software
    $targetState = Get-MixedStateId -Schema 'laplace-formal-target-inventory-v1' -Records $targetRecords
    $evidenceState = Get-MixedStateId -Schema $FormalPrepareSchema -Records $evidence
    return [pscustomobject]@{
        software_records = @($software | Sort-Object record_type, side, relative_path)
        target_records = @($targetRecords | Sort-Object record_type, side, relative_path)
        evidence_records = @($evidence | Sort-Object record_type, side, relative_path)
        software_state_id = $softwareState.id
        target_inventory_id = $targetState.id
        evidence_state_id = $evidenceState.id
        software_canonical = $softwareState.canonical
        target_canonical = $targetState.canonical
        evidence_canonical = $evidenceState.canonical
    }
}

function ConvertFrom-FormalPrepareWslStat {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$StatOutput,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$LinuxPath
    )
    $lines = @($StatOutput)
    # COMPAT: GNU stat names zero-byte ordinary files "regular empty file"; accept only its two exact ordinary-file descriptions.
    $match = if ($lines.Count -eq 1) { [regex]::Match([string]$lines[0], '^(\d+)\|(\d+)\|(\d+)\|regular (?:empty )?file$') } else { $null }
    if ($ExitCode -ne 0 -or $null -eq $match -or -not $match.Success) {
        throw "[UPGRADE_PREPARE_SOURCE_FAIL] WSL metadata is not a regular file: $LinuxPath"
    }
    return [pscustomobject]@{
        exists = $true
        attributes = $null
        sddl = $null
        posix_mode = $match.Groups[1].Value
        uid = [int]$match.Groups[2].Value
        gid = [int]$match.Groups[3].Value
    }
}

function Get-FormalPrepareWslFileMetadata {
    param([Parameter(Mandatory = $true)][string]$LinuxPath)
    # DEFENSE: --exec preserves the stat format and path as literal argv; bare -- is re-parsed by the WSL shell.
    $priorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $stat = @(& wsl.exe -d Ubuntu --exec stat -c '%a|%u|%g|%F' -- $LinuxPath 2>$null)
        $statExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $priorPreference }
    return ConvertFrom-FormalPrepareWslStat -StatOutput $stat -ExitCode $statExitCode -LinuxPath $LinuxPath
}

function Get-FormalPrepareFileMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Side,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Observation,
        [bool]$FixtureMode
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ exists = $false; attributes = $null; sddl = $null; posix_mode = $null; uid = $null; gid = $null }
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.PSIsContainer) {
        throw "[UPGRADE_PREPARE_SOURCE_FAIL] Symlink, reparse, or non-regular file is forbidden: $Path"
    }
    if ($Side -eq 'Frontend') {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        return [pscustomobject]@{ exists = $true; attributes = [string]$item.Attributes; sddl = $acl.Sddl; posix_mode = $null; uid = $null; gid = $null }
    }
    if ($FixtureMode) {
        return [pscustomobject]@{
            exists = $true
            attributes = [string]$item.Attributes
            sddl = $null
            posix_mode = [string]$Observation.fixture_backend_mode
            uid = [int]$Observation.fixture_backend_uid
            gid = [int]$Observation.fixture_backend_gid
        }
    }
    $linuxPath = '/home/serpal/.laplace_sentry_backend/' + $RelativePath.Replace('\\', '/').TrimStart('/')
    return Get-FormalPrepareWslFileMetadata -LinuxPath $linuxPath
}

function Assert-FormalPrepareAclAndOwner {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Observation,
        [bool]$FixtureMode
    )
    if ($FixtureMode) {
        if (-not [bool]$Observation.transaction_owner_ok) { throw '[UPGRADE_PREPARE_OWNER_FAIL] Fixture owner gate rejected.' }
        if (-not [bool]$Observation.transaction_acl_ok) { throw '[UPGRADE_PREPARE_ACL_FAIL] Fixture ACL gate rejected.' }
        return
    }
    $cursor = Get-NormalizedFullPath $Path
    while (-not (Test-Path -LiteralPath $cursor)) { $cursor = Split-Path -Parent $cursor }
    $acl = Get-Acl -LiteralPath $cursor -ErrorAction Stop
    $allowed = @([System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')
    if ($acl.Owner -notin $allowed) { throw "[UPGRADE_PREPARE_OWNER_FAIL] Unexpected owner: $($acl.Owner)" }
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -eq 'Deny' -or [string]$rule.IdentityReference -notin $allowed) {
            throw "[UPGRADE_PREPARE_ACL_FAIL] Unexpected ACL rule: $($rule.IdentityReference) $($rule.AccessControlType)"
        }
    }
}

function Get-FormalPrepareRequiredSpace {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Layout
    )
    $preimageBytes = [int64]0
    foreach ($record in $Layout) {
        if (Test-Path -LiteralPath $record.target_path -PathType Leaf) { $preimageBytes += [int64](Get-Item -LiteralPath $record.target_path -Force).Length }
    }
    foreach ($path in @(
        (Join-Path $Inputs.FrontendTarget 'version.txt'),
        (Join-Path $Inputs.BackendTarget 'version.txt'),
        (Join-Path $Inputs.FrontendTarget 'sentry_config.ini'),
        (Join-Path $Inputs.BackendTarget 'data\projects.json')
    )) { $preimageBytes += [int64](Get-Item -LiteralPath $path -Force -ErrorAction Stop).Length }
    $packageBytes = [int64]0
    foreach ($path in @(Get-ExpectedManagedGitPaths -Commit $FormalUpgradeTargetCommit)) {
        $packageBytes += [int64]((Get-GitOutput -Arguments @('cat-file', '-s', "$FormalUpgradeTargetCommit`:$path") | Select-Object -First 1).Trim())
    }
    $packageBytes += [int64](2 * [System.Text.Encoding]::ASCII.GetByteCount($FormalUpgradeTargetCommit.Substring(0, 7)))
    $required = $preimageBytes + (2 * $packageBytes) + $FormalPrepareJournalReserveBytes + $FormalPrepareSafetyMarginBytes
    return [pscustomobject]@{ preimage_bytes = $preimageBytes; package_bytes = $packageBytes; required_free_bytes = [int64]$required }
}

function Get-FormalPrepareFreeBytes {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionParent,
        [Parameter(Mandatory = $true)]$Observation,
        [bool]$FixtureMode
    )
    if ($FixtureMode) { return [int64]$Observation.free_bytes }
    $root = [System.IO.Path]::GetPathRoot((Get-NormalizedFullPath $TransactionParent))
    return [int64]([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
}

# =========================
# Manifest 與 durable journal
# =========================

function Save-FormalPrepareJsonDurable {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Payload
    )
    Write-JsonAtomic -Path $Path -Payload $Payload
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    try { $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function New-FormalPrepareManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)]$Records
    )
    $orderedRecords = @($Records | Sort-Object key)
    $lines = @($orderedRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress })
    $canonical = (@("schema=$FormalPrepareSchema", "manifest=$Type") + $lines) -join "`n"
    return [pscustomobject]@{
        schema = $FormalPrepareSchema
        manifest_type = $Type
        manifest_id = 'sha256:' + (Get-Utf8Sha256 $canonical)
        records = $orderedRecords
    }
}

function Get-FormalPrepareSourceManifestRecords {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)]$Observation,
        [bool]$FixtureMode
    )
    $records = @()
    foreach ($record in $Snapshot.target_records) {
        $root = if ($record.side -eq 'Frontend') { $Inputs.FrontendTarget } else { $Inputs.BackendTarget }
        $path = Join-Path $root $record.relative_path.Replace('/', '\\')
        $metadata = Get-FormalPrepareFileMetadata -Side $record.side -RelativePath $record.relative_path -Path $path -Observation $Observation -FixtureMode $FixtureMode
        $records += [pscustomobject][ordered]@{
            key = "$($record.side)/$($record.relative_path)"
            record_type = $record.record_type
            source_path = $path
            exists = [bool]$record.exists
            length = $record.length
            sha256 = $record.sha256
            last_write_utc = $record.last_write_utc
            attributes = $metadata.attributes
            sddl = $metadata.sddl
            posix_mode = $metadata.posix_mode
            uid = $metadata.uid
            gid = $metadata.gid
        }
    }
    $runtime = @($Snapshot.evidence_records | Where-Object { $_.record_type -eq 'runtime_observation' } | Select-Object -First 1)[0]
    $records += [pscustomobject][ordered]@{
        key = 'Runtime/observation.json'
        record_type = $runtime.record_type
        source_path = $null
        exists = $true
        length = $runtime.length
        sha256 = $runtime.sha256
        last_write_utc = $null
        attributes = $null
        sddl = $null
        posix_mode = $null
        uid = $null
        gid = $null
        observation = $Observation
    }
    return $records
}

function Get-FormalPreparePreimageManifestRecords {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$Preimage,
        [Parameter(Mandatory = $true)]$SourceManifest
    )
    $records = @()
    foreach ($record in $Layout) {
        $source = @($SourceManifest.records | Where-Object { $_.key -eq "$($record.side)/$($record.relative_path)" } | Select-Object -First 1)[0]
        $copy = $Preimage.managed[$record.git_path]
        $records += [pscustomobject][ordered]@{
            key = $source.key
            target_path = $source.source_path
            existed_before = [bool]$source.exists
            length = $source.length
            sha256 = $source.sha256
            last_write_utc = $source.last_write_utc
            attributes = $source.attributes
            sddl = $source.sddl
            posix_mode = $source.posix_mode
            uid = $source.uid
            gid = $source.gid
            artifact_path = $copy.path
            artifact_sha256 = if ($copy.path) { Get-FileSha256 $copy.path } else { $null }
        }
    }
    foreach ($copy in $Preimage.protected) {
        $source = @($SourceManifest.records | Where-Object { $_.key -eq "$($copy.side)/$($copy.relative_path)" } | Select-Object -First 1)[0]
        $records += [pscustomobject][ordered]@{
            key = $source.key
            target_path = $source.source_path
            existed_before = $true
            length = $source.length
            sha256 = $source.sha256
            last_write_utc = $source.last_write_utc
            attributes = $source.attributes
            sddl = $source.sddl
            posix_mode = $source.posix_mode
            uid = $source.uid
            gid = $source.gid
            artifact_path = $copy.preimage_path
            artifact_sha256 = Get-FileSha256 $copy.preimage_path
        }
    }
    return $records
}

function Get-FormalPreparePackageManifestRecords {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$Package
    )
    $records = @()
    foreach ($record in @($Layout | Where-Object { $_.package_git_blob })) {
        $artifact = $Package.files[$record.git_path]
        $records += [pscustomobject][ordered]@{
            key = $record.git_path
            git_blob = $record.package_git_blob
            artifact_path = $artifact.path
            artifact_sha256 = $artifact.sha256
            length = $artifact.length
        }
    }
    foreach ($side in @('Backend', 'Frontend')) {
        $marker = $Package.markers[$side]
        $records += [pscustomobject][ordered]@{
            key = "$side/version.txt"
            git_blob = $null
            artifact_path = $marker.path
            artifact_sha256 = $marker.sha256
            length = $marker.length
        }
    }
    return $records
}

function Assert-FormalPrepareManifestIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionRoot,
        [Parameter(Mandatory = $true)]$ManifestReference
    )
    if (-not (Test-StrictPathInside -Candidate $ManifestReference.path -Container $TransactionRoot) -or
        -not (Test-Path -LiteralPath $ManifestReference.path -PathType Leaf) -or
        -not (Get-FileSha256 $ManifestReference.path).Equals([string]$ManifestReference.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '[UPGRADE_PREPARE_RECOVERY_REQUIRED] Manifest file is missing, escaped, or changed.'
    }
    $manifest = Get-Content -LiteralPath $ManifestReference.path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($manifest.manifest_id -ne $ManifestReference.id) {
        throw '[UPGRADE_PREPARE_RECOVERY_REQUIRED] Manifest ID changed.'
    }
    foreach ($record in @($manifest.records)) {
        if (-not $record.PSObject.Properties['artifact_path'] -or -not $record.artifact_path) { continue }
        if (-not (Test-StrictPathInside -Candidate $record.artifact_path -Container $TransactionRoot) -or
            -not (Test-Path -LiteralPath $record.artifact_path -PathType Leaf) -or
            -not (Get-FileSha256 $record.artifact_path).Equals([string]$record.artifact_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_PREPARE_RECOVERY_REQUIRED] Evidence artifact changed: $($record.key)"
        }
    }
    return $manifest
}

function Assert-FormalPrepareTransactionIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionRoot,
        [Parameter(Mandatory = $true)]$Journal
    )
    if (-not (Test-PathsEqual -First $TransactionRoot -Second $Journal.transaction_root) -or
        $Journal.schema -ne $FormalPrepareSchema -or $Journal.state -ne 'prepared_pending_apply' -or
        [int]$Journal.formal_target_write_count -ne 0) {
        throw '[UPGRADE_PREPARE_RECOVERY_REQUIRED] Prepared transaction boundary or state is invalid.'
    }
    foreach ($name in @('source', 'preimage', 'package')) {
        [void](Assert-FormalPrepareManifestIntegrity -TransactionRoot $TransactionRoot -ManifestReference $Journal.manifests.$name)
    }
}

function Find-FormalPreparedTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionParent,
        [Parameter(Mandatory = $true)]$Snapshot
    )
    if (-not (Test-Path -LiteralPath $TransactionParent -PathType Container)) { return $null }
    $matches = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $TransactionParent -Directory -Force | Sort-Object Name)) {
        $journalPath = Join-Path $directory.FullName 'transaction-journal.json'
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            throw '[UPGRADE_PREPARE_RECOVERY_REQUIRED] Transaction directory has no journal.'
        }
        try { $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
        catch { throw '[UPGRADE_PREPARE_RECOVERY_REQUIRED] Transaction journal is unreadable or corrupt.' }
        if ($journal.state -eq 'invalidated') {
            continue
        }
        if ($journal.state -ne 'prepared_pending_apply') {
            throw "[UPGRADE_PREPARE_RECOVERY_REQUIRED] Transaction requires explicit recovery: $($journal.state)"
        }
        if ($journal.target_commit -eq $FormalUpgradeTargetCommit -and
            $journal.software_state_id -eq $Snapshot.software_state_id -and
            $journal.evidence_state_id -eq $Snapshot.evidence_state_id) {
            Assert-FormalPrepareTransactionIntegrity -TransactionRoot $directory.FullName -Journal $journal
            $matches += $journal
        }
    }
    if ($matches.Count -gt 1) { throw '[UPGRADE_PREPARE_RECOVERY_REQUIRED] Multiple matching prepared transactions exist.' }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

# =========================
# Prepare orchestration：只落交易證據，不寫目標
# =========================

function New-FormalPrepareFailureResult {
    param([Parameter(Mandatory = $true)][string]$Message)
    $journal = $script:FormalPrepareFailureJournal
    if ($journal) {
        return [pscustomobject]@{
            schema = $journal.schema
            mode = $journal.mode
            result = $journal.result
            state = $journal.state
            failure_phase = $journal.failure_phase
            transaction_id = $journal.transaction_id
            transaction_root = $journal.transaction_root
            target_commit = $journal.target_commit
            software_state_id = $journal.software_state_id
            evidence_state_id = $journal.evidence_state_id
            manifests = $journal.manifests
            error = $journal.error
            formal_target_write_count = [int]$journal.formal_target_write_count
            warnings = @($journal.warnings)
        }
    }
    return [pscustomobject]@{
        schema = $FormalPrepareSchema
        mode = 'PrepareFormal'
        result = 'failed'
        state = 'rejected'
        failure_phase = 'before_transaction'
        transaction_id = $null
        transaction_root = $null
        error = $Message
        formal_target_write_count = 0
    }
}

function ConvertTo-FormalPrepareResult {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][ValidateSet('prepared', 'already_prepared')][string]$Result
    )
    return [pscustomobject]@{
        schema = $Journal.schema
        mode = 'PrepareFormal'
        result = $Result
        state = $Journal.state
        transaction_id = $Journal.transaction_id
        transaction_root = $Journal.transaction_root
        target_commit = $Journal.target_commit
        software_state_id = $Journal.software_state_id
        evidence_state_id = $Journal.evidence_state_id
        manifests = $Journal.manifests
        formal_target_write_count = [int]$Journal.formal_target_write_count
        warnings = @($Journal.warnings)
    }
}

function Invoke-FormalPrepareMode {
    param([Parameter(Mandatory = $true)]$Inputs)
    $script:FormalPrepareFailureJournal = $null
    $fixtureMode = Test-FormalPrepareFixtureMode -Inputs $Inputs
    $script:FormalPrepareObservationPath = $Inputs.PreflightObservationPath
    Assert-FormalPrepareRepoBasis -FixtureMode $fixtureMode
    $observation = Get-FormalPrepareObservation -Inputs $Inputs
    if (-not $fixtureMode) {
        # Live observation has no file; materialize nothing before the transaction exists.
        $script:FormalPrepareObservationPath = $null
        if ([bool](Get-OptionalProperty -Object $observation -Name 'lock_exists' -Default $false) -or
            @(Get-OptionalProperty -Object $observation -Name 'ui' -Default @()).Count -gt 0 -or
            @(Get-OptionalProperty -Object $observation -Name 'daemon' -Default @()).Count -gt 0 -or
            @(Get-OptionalProperty -Object $observation -Name 'workers' -Default @()).Count -gt 0) {
            throw '[UPGRADE_PREPARE_RUNTIME_FAIL] Live runtime or lock is active.'
        }
        foreach ($record in @(Get-OptionalProperty -Object $observation -Name 'registry' -Default @())) {
            if ([bool](Get-OptionalProperty -Object $record -Name 'proc_exists' -Default $false) -or
                [bool](Get-OptionalProperty -Object $record -Name 'owned' -Default $false) -or
                [bool](Get-OptionalProperty -Object $record -Name 'ambiguous' -Default $false)) {
                throw '[UPGRADE_PREPARE_RUNTIME_FAIL] Live registry/process ownership is active or ambiguous.'
            }
        }
    }
    else { Assert-FormalPrepareObservationSafe -Observation $observation }

    $layout = Resolve-MixedRepairLayout -Inputs $Inputs
    $snapshot = Get-FormalPrepareSourceSnapshot -Inputs $Inputs -Layout $layout -Observation $observation
    $transactionParent = Get-FormalPrepareTransactionParent -Inputs $Inputs
    Assert-FormalPrepareNoReparse -Path $transactionParent
    Assert-FormalPrepareAclAndOwner -Path $transactionParent -Observation $observation -FixtureMode $fixtureMode
    $space = Get-FormalPrepareRequiredSpace -Inputs $Inputs -Layout $layout
    $freeBytes = Get-FormalPrepareFreeBytes -TransactionParent $transactionParent -Observation $observation -FixtureMode $fixtureMode
    if ($freeBytes -lt $space.required_free_bytes) {
        throw "[UPGRADE_PREPARE_SPACE_FAIL] free=$freeBytes required=$($space.required_free_bytes)"
    }

    $existing = Find-FormalPreparedTransaction -TransactionParent $transactionParent -Snapshot $snapshot
    if ($existing) { return ConvertTo-FormalPrepareResult -Journal $existing -Result 'already_prepared' }

    # Side effects begin only after every hard gate and reentry check passed.
    if (-not (Test-Path -LiteralPath $transactionParent)) {
        New-Item -ItemType Directory -Path $transactionParent -Force -ErrorAction Stop | Out-Null
    }
    Assert-FormalPrepareNoReparse -Path $transactionParent
    Assert-FormalPrepareAclAndOwner -Path $transactionParent -Observation $observation -FixtureMode $fixtureMode
    $transactionId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '-' + [Guid]::NewGuid().ToString('N')
    $transactionRoot = Join-Path $transactionParent $transactionId
    New-Item -ItemType Directory -Path $transactionRoot -ErrorAction Stop | Out-Null
    Assert-FormalPrepareNoReparse -Path $transactionRoot
    Assert-FormalPrepareAclAndOwner -Path $transactionRoot -Observation $observation -FixtureMode $fixtureMode

    $journalPath = Join-Path $transactionRoot 'transaction-journal.json'
    $warnings = @()
    foreach ($record in @(Get-OptionalProperty -Object $observation -Name 'registry' -Default @())) {
        if (-not [bool](Get-OptionalProperty -Object $record -Name 'proc_exists' -Default $false) -and
            -not [bool](Get-OptionalProperty -Object $record -Name 'ambiguous' -Default $false)) {
            $warnings += [pscustomobject]@{ tag = '[UPGRADE_REGISTRY_STALE]'; pid = $record.pid; preserved = $true }
        }
    }
    $journal = [pscustomobject]@{
        schema = $FormalPrepareSchema
        mode = 'PrepareFormal'
        state = 'preparing'
        result = 'preparing'
        transaction_id = $transactionId
        transaction_root = $transactionRoot
        transaction_parent = $transactionParent
        fixture_mode = $fixtureMode
        repo_head = Get-HeadCommit
        target_commit = $FormalUpgradeTargetCommit
        targets = [pscustomobject]@{ frontend = $Inputs.FrontendTarget; backend = $Inputs.BackendTarget }
        software_state_id = $snapshot.software_state_id
        target_inventory_id = $snapshot.target_inventory_id
        evidence_state_id = $snapshot.evidence_state_id
        required_space = $space
        observed_free_bytes = $freeBytes
        manifests = [pscustomobject]@{ source = $null; preimage = $null; package = $null }
        formal_target_write_count = 0
        failure_phase = $null
        warnings = $warnings
        events = @('preparing')
        error = $null
        created_at_utc = [DateTime]::UtcNow.ToString('o')
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    try {
        Save-MixedRepairJournal -JournalPath $journalPath -Journal $journal
        if ($MixedFailureInjection -in @('Prepare', 'Journal')) {
            throw "[UPGRADE_PREPARE_INJECTED_FAIL] $MixedFailureInjection interruption after durable preparing journal."
        }

        $sourceRecords = Get-FormalPrepareSourceManifestRecords -Inputs $Inputs -Snapshot $snapshot -Observation $observation -FixtureMode $fixtureMode
        $sourceManifest = New-FormalPrepareManifest -Type 'source' -Records $sourceRecords
        $sourcePath = Join-Path $transactionRoot 'source-manifest.json'
        Save-FormalPrepareJsonDurable -Path $sourcePath -Payload $sourceManifest

        $workInputs = $Inputs.PSObject.Copy()
        $workInputs.StagingRoot = $transactionRoot
        $preimage = New-MixedPreimage -Inputs $workInputs -Layout $layout
        $package = Export-MixedGitPackage -Inputs $workInputs -Layout $layout
        $preimageManifest = New-FormalPrepareManifest -Type 'preimage' -Records (Get-FormalPreparePreimageManifestRecords -Layout $layout -Preimage $preimage -SourceManifest $sourceManifest)
        $packageManifest = New-FormalPrepareManifest -Type 'package' -Records (Get-FormalPreparePackageManifestRecords -Layout $layout -Package $package)
        $preimagePath = Join-Path $transactionRoot 'preimage-manifest.json'
        $packagePath = Join-Path $transactionRoot 'package-manifest.json'
        Save-FormalPrepareJsonDurable -Path $preimagePath -Payload $preimageManifest
        Save-FormalPrepareJsonDurable -Path $packagePath -Payload $packageManifest
        $journal.manifests = [pscustomobject]@{
            source = [pscustomobject]@{ path = $sourcePath; id = $sourceManifest.manifest_id; sha256 = Get-FileSha256 $sourcePath }
            preimage = [pscustomobject]@{ path = $preimagePath; id = $preimageManifest.manifest_id; sha256 = Get-FileSha256 $preimagePath }
            package = [pscustomobject]@{ path = $packagePath; id = $packageManifest.manifest_id; sha256 = Get-FileSha256 $packagePath }
        }
        $journal.events += 'artifacts-sealed'
        Save-MixedRepairJournal -JournalPath $journalPath -Journal $journal

        $secondObservation = Get-FormalPrepareObservation -Inputs $Inputs
        $secondLayout = Resolve-MixedRepairLayout -Inputs $Inputs
        $secondSnapshot = Get-FormalPrepareSourceSnapshot -Inputs $Inputs -Layout $secondLayout -Observation $secondObservation
        if ($MixedFailureInjection -eq 'SecondSnapshot') { $secondSnapshot.evidence_canonical += '|injected-drift' }
        if ($secondSnapshot.software_canonical -cne $snapshot.software_canonical -or
            $secondSnapshot.target_canonical -cne $snapshot.target_canonical -or
            $secondSnapshot.evidence_canonical -cne $snapshot.evidence_canonical) {
            throw '[UPGRADE_PREPARE_SOURCE_CHANGED] Source, protected, runtime, or registry evidence changed during prepare.'
        }
        if ($MixedFailureInjection -eq 'EvidenceTamper') {
            'tampered' | Add-Content -LiteralPath $packageManifest.records[0].artifact_path -Encoding UTF8
        }
        foreach ($name in @('source', 'preimage', 'package')) {
            [void](Assert-FormalPrepareManifestIntegrity -TransactionRoot $transactionRoot -ManifestReference $journal.manifests.$name)
        }
        $finalSnapshot = Get-FormalPrepareSourceSnapshot -Inputs $Inputs -Layout (Resolve-MixedRepairLayout -Inputs $Inputs) -Observation (Get-FormalPrepareObservation -Inputs $Inputs)
        if ($finalSnapshot.target_canonical -cne $snapshot.target_canonical) {
            throw '[UPGRADE_PREPARE_TARGET_WRITE_FAIL] Formal target inventory changed during prepare.'
        }
        $journal.state = 'prepared_pending_apply'
        $journal.result = 'prepared'
        $journal.events += @('second-snapshot-verified', 'evidence-integrity-verified', 'prepared_pending_apply')
        Save-MixedRepairJournal -JournalPath $journalPath -Journal $journal
        Assert-FormalPrepareTransactionIntegrity -TransactionRoot $transactionRoot -Journal $journal
        return ConvertTo-FormalPrepareResult -Journal $journal -Result 'prepared'
    }
    catch {
        $journal.state = 'prepare_invalidated'
        $journal.result = 'failed'
        $journal.failure_phase = 'after_transaction'
        $journal.error = $_.Exception.Message
        $journal.events += 'prepare_invalidated'
        Save-MixedRepairJournal -JournalPath $journalPath -Journal $journal
        $script:FormalPrepareFailureJournal = $journal
        throw $journal.error
    }
}
