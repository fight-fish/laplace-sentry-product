<#
.SYNOPSIS
驗證一筆明確指定的 PrepareFormal 交易是否仍具備正式套用資格，但不執行套用。

.DESCRIPTION
Purpose: revalidate one explicitly selected prepared transaction, then provide one shared apply/recovery engine for strict-TEMP proof and a non-public fixed-target formal capability.
Inputs: normalized upgrade inputs plus an explicit transaction directory; fixed formal targets for live mode, or complete isolated TEMP targets and observation JSON for fixture mode.
Outputs: one JSON eligibility result with traceable checks and rejection tags.
SSOT Output: stdout JSON plus the selected transaction's existing transaction-journal.json; no second progress/state file is created.
Exit codes: the caller maps eligible to 0 and every rejection or indeterminate failure to 7.
SKIP conditions: none; the validator never auto-selects a transaction and never prepares one.
FAIL conditions: boundary, identity, age, repository, evidence, target, protected-data, metadata, runtime, or duplicate-transaction checks fail.
Order-sensitive checks: explicit identity and sealed evidence are verified before current target/runtime eligibility is accepted.
Side effects: validation is read-only. Fixture modes update only an existing fixture journal and strict-TEMP fake targets. Internal formal modes are locked to the fixed Windows/WSL targets and one existing formal transaction, never manage processes/registry/Git, and require separate execution authority.
#>

# 這支腳本在做什麼：驗證指定 prepared transaction，並以同一份 journal 承接 TEMP 演練與鎖死固定位置的內部正式 apply／recovery 能力。
# 這支腳本不做什麼：不找最新交易、不重跑 prepare、不提供公開 apply／rollback、不刪交易、不改程序或 registry。
# 常改區塊：資格檢查、fixture action 推導、故障點、還原與 manifest／現況比對。
# 不要亂動的區塊：明確交易選擇、30 分鐘上限、正式路徑硬拒絕、使用者資料保護與單一 journal SSOT。

Set-StrictMode -Version Latest

$FormalApplyEligibilitySchema = 'laplace-formal-apply-eligibility-v1'
$FormalApplyMaximumAgeMinutes = 30
$FormalApplyFixtureSchema = 'laplace-formal-apply-fixture-v1'
$FormalApplyExecutionSchema = 'laplace-formal-apply-execution-v2'
$FormalApplyLockPath = Join-Path $env:LOCALAPPDATA 'LaplaceSentryUpgrade\formal-upgrade.lock'

function Test-FormalApplyFixtureMode {
    param([Parameter(Mandatory = $true)]$Inputs)
    if ($Inputs.Mode -in @('ApplyFormalInternal', 'RecoverFormalInternal')) { return $false }
    if ($Inputs.Mode -in @('ApplyFormalFixture', 'RecoverFormalFixture')) { return $true }
    return [bool]($Inputs.IsolationRoot -or $Inputs.PreflightObservationPath)
}

function Get-FormalApplyFailureInfo {
    param([Parameter(Mandatory = $true)][string]$Message)
    $match = [regex]::Match($Message, '\[(UPGRADE_APPLY_[A-Z_]+)\]')
    $tag = if ($match.Success) { "[$($match.Groups[1].Value)]" } else { '[UPGRADE_APPLY_VALIDATION_FAIL]' }
    $check = switch -Regex ($tag) {
        'BOUNDARY' { 'boundary'; break }
        'TRANSACTION' { 'transaction'; break }
        'JOURNAL' { 'transaction'; break }
        'LOCK' { 'runtime'; break }
        'AGE' { 'age'; break }
        'REPO' { 'repository'; break }
        'EVIDENCE' { 'evidence'; break }
        'PROTECTED' { 'protected_data'; break }
        'METADATA' { 'metadata'; break }
        'RUNTIME' { 'runtime'; break }
        'TARGET' { 'targets'; break }
        default { 'validation' }
    }
    return [pscustomobject]@{ tag = $tag; check_id = $check }
}

function New-FormalApplyValidationResult {
    param($Inputs)
    return [pscustomobject]@{
        schema = $FormalApplyEligibilitySchema
        mode = 'ValidateFormalApply'
        result = 'rejected'
        eligible = $false
        transaction_id = $null
        transaction_root = if ($Inputs) { $Inputs.TransactionRoot } else { $null }
        target_commit = $null
        max_age_minutes = $FormalApplyMaximumAgeMinutes
        age_seconds = $null
        checks = [System.Collections.Generic.List[object]]::new()
        failures = [System.Collections.Generic.List[object]]::new()
        formal_target_write_count = 0
    }
}

function Add-FormalApplyCheck {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail', 'indeterminate')][string]$Status,
        [Parameter(Mandatory = $true)][string]$TruthSource,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    $Result.checks.Add([pscustomobject]@{ id = $Id; status = $Status; truth_source = $TruthSource; reason = $Reason })
}

function New-FormalApplyValidationFailureResult {
    param(
        $Inputs,
        [Parameter(Mandatory = $true)][string]$Message,
        $Result
    )
    if (-not $Result) { $Result = New-FormalApplyValidationResult -Inputs $Inputs }
    $failure = Get-FormalApplyFailureInfo -Message $Message
    $Result.result = 'rejected'
    $Result.eligible = $false
    $Result.failures.Add([pscustomobject]@{ tag = $failure.tag; check_id = $failure.check_id; message = $Message })
    Add-FormalApplyCheck -Result $Result -Id $failure.check_id -Status 'fail' -TruthSource 'current read-only validation' -Reason $Message
    return $Result
}

function Assert-FormalApplyValidationBoundary {
    param([Parameter(Mandatory = $true)]$Inputs)
    if (-not $Inputs.TransactionRoot) {
        throw '[UPGRADE_APPLY_BOUNDARY_FAIL] ValidateFormalApply requires one explicit transaction directory.'
    }
    $fixtureMode = Test-FormalApplyFixtureMode -Inputs $Inputs
    if (-not $fixtureMode) {
        if (-not (Test-PathsEqual -First $Inputs.FrontendTarget -Second $FormalFrontendTarget) -or
            -not (Test-PathsEqual -First $Inputs.BackendTarget -Second $FormalBackendTarget)) {
            throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Live validation only accepts the fixed formal targets.'
        }
        if (-not (Test-StrictPathInside -Candidate $Inputs.TransactionRoot -Container $FormalPrepareTransactionsParent)) {
            throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Explicit live transaction must be a strict child of the formal transaction parent.'
        }
    }
    else {
        if (-not $Inputs.IsolationRoot -or -not $Inputs.PreflightObservationPath) {
            throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Fixture validation requires IsolationRoot and PreflightObservationPath.'
        }
        if (-not (Test-Path -LiteralPath $Inputs.IsolationRoot -PathType Container) -or
            -not (Test-StrictPathInside -Candidate $Inputs.IsolationRoot -Container $TempRoot)) {
            throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Fixture IsolationRoot must be an existing strict child of system TEMP.'
        }
        foreach ($candidate in @($Inputs.FrontendTarget, $Inputs.BackendTarget, $Inputs.TransactionRoot, $Inputs.PreflightObservationPath)) {
            if (-not (Test-StrictPathInside -Candidate $candidate -Container $Inputs.IsolationRoot)) {
                throw "[UPGRADE_APPLY_BOUNDARY_FAIL] Fixture path escaped IsolationRoot: $candidate"
            }
            foreach ($forbidden in @($RepoRoot, $FormalFrontendTarget, $FormalBackendTarget, $FormalPrepareTransactionsParent)) {
                if (Test-PathsOverlap -First $candidate -Second $forbidden) {
                    throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Fixture path overlaps a repository or formal path.'
                }
            }
        }
        $peers = @($Inputs.FrontendTarget, $Inputs.BackendTarget, $Inputs.TransactionRoot, $Inputs.PreflightObservationPath)
        for ($first = 0; $first -lt $peers.Count; $first++) {
            for ($second = $first + 1; $second -lt $peers.Count; $second++) {
                if (Test-PathsOverlap -First $peers[$first] -Second $peers[$second]) {
                    throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Fixture targets, transaction, and observation must be mutually exclusive.'
                }
            }
        }
        if ($Inputs.BackendTarget -match '(?i)(^|[\\/])\.laplace_sentry_backend([\\/]|$)') {
            throw '[UPGRADE_APPLY_BOUNDARY_FAIL] A formal-runtime-shaped backend fixture is forbidden.'
        }
    }
    foreach ($path in @($Inputs.FrontendTarget, $Inputs.BackendTarget, $Inputs.TransactionRoot)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "[UPGRADE_APPLY_BOUNDARY_FAIL] Required directory is missing: $path"
        }
        try { Assert-FormalPrepareNoReparse -Path $path }
        catch { throw "[UPGRADE_APPLY_BOUNDARY_FAIL] $($_.Exception.Message)" }
    }
    if ($fixtureMode -and -not (Test-Path -LiteralPath $Inputs.PreflightObservationPath -PathType Leaf)) {
        throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Fixture observation JSON is missing.'
    }
    if ($fixtureMode) {
        try { Assert-FormalPrepareNoReparse -Path $Inputs.PreflightObservationPath }
        catch { throw "[UPGRADE_APPLY_BOUNDARY_FAIL] $($_.Exception.Message)" }
    }
}

function Assert-FormalApplyTransactionIdentity {
    param(
        [Parameter(Mandatory = $true)]$Inputs,
        [Parameter(Mandatory = $true)]$Journal,
        [bool]$FixtureMode
    )
    $root = Get-NormalizedFullPath $Inputs.TransactionRoot
    $leaf = Split-Path -Leaf $root
    $parent = Split-Path -Parent $root
    foreach ($required in @('schema', 'mode', 'state', 'transaction_id', 'transaction_root', 'transaction_parent', 'repo_head', 'target_commit', 'targets', 'manifests', 'created_at_utc', 'formal_target_write_count')) {
        if ($null -eq $Journal.PSObject.Properties[$required]) {
            throw "[UPGRADE_APPLY_TRANSACTION_FAIL] Journal is missing required field: $required"
        }
    }
    if ($Journal.schema -ne $FormalPrepareSchema -or $Journal.mode -ne 'PrepareFormal' -or
        $Journal.state -ne 'prepared_pending_apply' -or [int]$Journal.formal_target_write_count -ne 0) {
        throw '[UPGRADE_APPLY_TRANSACTION_FAIL] Journal schema, mode, state, or zero-write seal is invalid.'
    }
    if ($leaf -cne [string]$Journal.transaction_id -or
        -not (Test-PathsEqual -First $root -Second ([string]$Journal.transaction_root)) -or
        -not (Test-PathsEqual -First $parent -Second ([string]$Journal.transaction_parent))) {
        throw '[UPGRADE_APPLY_TRANSACTION_FAIL] Explicit root, transaction ID, and journal paths disagree.'
    }
    if ([bool](Get-OptionalProperty -Object $Journal -Name 'fixture_mode' -Default $false) -ne $FixtureMode) {
        throw '[UPGRADE_APPLY_TRANSACTION_FAIL] Journal fixture identity disagrees with the current invocation.'
    }
    if (-not (Test-PathsEqual -First $Inputs.FrontendTarget -Second ([string]$Journal.targets.frontend)) -or
        -not (Test-PathsEqual -First $Inputs.BackendTarget -Second ([string]$Journal.targets.backend))) {
        throw '[UPGRADE_APPLY_TRANSACTION_FAIL] Journal targets disagree with the explicitly selected targets.'
    }
    if (-not $Journal.target_commit.Equals($FormalPrepareTargetCommit, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '[UPGRADE_APPLY_TRANSACTION_FAIL] Journal target commit is not the ruled formal target commit.'
    }
}

function Get-FormalApplyTransactionAge {
    param([Parameter(Mandatory = $true)]$Journal)
    $created = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact([string]$Journal.created_at_utc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$created)) {
        throw '[UPGRADE_APPLY_AGE_FAIL] Journal created_at_utc is invalid.'
    }
    $idMatch = [regex]::Match([string]$Journal.transaction_id, '^(\d{8}T\d{13}Z)-[0-9a-f]{32}$')
    if (-not $idMatch.Success) { throw '[UPGRADE_APPLY_AGE_FAIL] Transaction ID timestamp shape is invalid.' }
    $idTime = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($idMatch.Groups[1].Value, 'yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$idTime)) {
        throw '[UPGRADE_APPLY_AGE_FAIL] Transaction ID timestamp is invalid.'
    }
    if ([Math]::Abs(($created.ToUniversalTime() - $idTime.ToUniversalTime()).TotalSeconds) -gt 5) {
        throw '[UPGRADE_APPLY_AGE_FAIL] Journal creation time disagrees with the transaction ID.'
    }
    $age = ([DateTime]::UtcNow - $created.ToUniversalTime()).TotalSeconds
    if ($age -lt -5 -or $age -gt ($FormalApplyMaximumAgeMinutes * 60)) {
        throw "[UPGRADE_APPLY_AGE_FAIL] Prepared transaction age is outside 0-$FormalApplyMaximumAgeMinutes minutes: $([Math]::Round($age, 3)) seconds."
    }
    return [double]$age
}

function Assert-FormalApplyNoCompetingTransaction {
    param([Parameter(Mandatory = $true)][string]$TransactionRoot)
    $parent = Split-Path -Parent (Get-NormalizedFullPath $TransactionRoot)
    foreach ($directory in @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction Stop)) {
        if (Test-PathsEqual -First $directory.FullName -Second $TransactionRoot) { continue }
        $journalPath = Join-Path $directory.FullName 'transaction-journal.json'
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            throw '[UPGRADE_APPLY_TRANSACTION_FAIL] A sibling transaction directory has no journal.'
        }
        try { $sibling = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
        catch { throw '[UPGRADE_APPLY_TRANSACTION_FAIL] A sibling transaction journal is unreadable.' }
        if ([string]$sibling.state -notin @('committed', 'rolled_back')) {
            throw "[UPGRADE_APPLY_TRANSACTION_FAIL] A competing nonterminal transaction exists: $($directory.Name) state=$($sibling.state)"
        }
    }
}

function Read-FormalApplyManifest {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Reference
    )
    $expectedPath = Join-Path $TransactionRoot "$Name-manifest.json"
    if (-not (Test-PathsEqual -First $expectedPath -Second ([string]$Reference.path))) {
        throw "[UPGRADE_APPLY_EVIDENCE_FAIL] $Name manifest path is not canonical."
    }
    try { $manifest = Assert-FormalPrepareManifestIntegrity -TransactionRoot $TransactionRoot -ManifestReference $Reference }
    catch { throw "[UPGRADE_APPLY_EVIDENCE_FAIL] $($_.Exception.Message)" }
    if ($manifest.schema -ne $FormalPrepareSchema -or $manifest.manifest_type -ne $Name) {
        throw "[UPGRADE_APPLY_EVIDENCE_FAIL] $Name manifest schema/type is invalid."
    }
    $rebuilt = New-FormalPrepareManifest -Type $Name -Records @($manifest.records)
    if ($rebuilt.manifest_id -ne $manifest.manifest_id -or $rebuilt.manifest_id -ne $Reference.id) {
        throw "[UPGRADE_APPLY_EVIDENCE_FAIL] $Name canonical manifest ID is invalid."
    }
    $keys = @($manifest.records | ForEach-Object { [string]$_.key })
    if (@($keys | Group-Object | Where-Object Count -ne 1).Count -gt 0) {
        throw "[UPGRADE_APPLY_EVIDENCE_FAIL] $Name manifest has duplicate keys."
    }
    return $manifest
}

function Assert-FormalApplyKeySet {
    param([string]$Name, [string[]]$Expected, [string[]]$Actual)
    $expectedKeys = @($Expected | Sort-Object -Unique)
    $actualKeys = @($Actual | Sort-Object -Unique)
    if ($expectedKeys.Count -ne $actualKeys.Count -or @(Compare-Object $expectedKeys $actualKeys).Count -gt 0) {
        throw "[UPGRADE_APPLY_EVIDENCE_FAIL] $Name manifest key set is invalid."
    }
}

function Get-FormalApplyRecord {
    param($Manifest, [string]$Key)
    $records = @($Manifest.records | Where-Object { $_.key -ceq $Key })
    if ($records.Count -ne 1) { throw "[UPGRADE_APPLY_EVIDENCE_FAIL] Expected one record for $Key." }
    return $records[0]
}

function Test-FormalApplyFieldEqual {
    param($First, $Second, [string]$Name)
    $left = Get-OptionalProperty -Object $First -Name $Name -Default $null
    $right = Get-OptionalProperty -Object $Second -Name $Name -Default $null
    return ($left | ConvertTo-Json -Depth 8 -Compress) -ceq ($right | ConvertTo-Json -Depth 8 -Compress)
}

function Assert-FormalApplySourceCurrent {
    param($SourceManifest, $FreshManifest)
    foreach ($fresh in @($FreshManifest.records | Where-Object key -ne 'Runtime/observation.json')) {
        $sealed = Get-FormalApplyRecord -Manifest $SourceManifest -Key $fresh.key
        $contentFields = @('record_type', 'source_path', 'exists', 'length', 'sha256')
        foreach ($field in $contentFields) {
            if (-not (Test-FormalApplyFieldEqual -First $sealed -Second $fresh -Name $field)) {
                $tag = if ($fresh.record_type -eq 'protected') { 'UPGRADE_APPLY_PROTECTED_FAIL' } else { 'UPGRADE_APPLY_TARGET_FAIL' }
                throw "[$tag] Current content drifted for $($fresh.key) field=$field."
            }
        }
        foreach ($field in @('last_write_utc', 'attributes', 'sddl', 'posix_mode', 'uid', 'gid')) {
            if (-not (Test-FormalApplyFieldEqual -First $sealed -Second $fresh -Name $field)) {
                throw "[UPGRADE_APPLY_METADATA_FAIL] Current metadata drifted for $($fresh.key) field=$field."
            }
        }
    }
    $sealedRuntime = Get-FormalApplyRecord -Manifest $SourceManifest -Key 'Runtime/observation.json'
    $freshRuntime = Get-FormalApplyRecord -Manifest $FreshManifest -Key 'Runtime/observation.json'
    foreach ($field in @('length', 'sha256', 'observation')) {
        if (-not (Test-FormalApplyFieldEqual -First $sealedRuntime -Second $freshRuntime -Name $field)) {
            throw "[UPGRADE_APPLY_RUNTIME_FAIL] Runtime evidence drifted field=$field."
        }
    }
}

function Assert-FormalApplyPreimageContract {
    param($SourceManifest, $PreimageManifest)
    $sourceTargets = @($SourceManifest.records | Where-Object key -ne 'Runtime/observation.json')
    Assert-FormalApplyKeySet -Name 'preimage' -Expected @($sourceTargets.key) -Actual @($PreimageManifest.records.key)
    foreach ($source in $sourceTargets) {
        $preimage = Get-FormalApplyRecord -Manifest $PreimageManifest -Key $source.key
        if (-not (Test-PathsEqual -First ([string]$source.source_path) -Second ([string]$preimage.target_path)) -or
            [bool]$source.exists -ne [bool]$preimage.existed_before) {
            throw "[UPGRADE_APPLY_EVIDENCE_FAIL] Preimage identity is invalid for $($source.key)."
        }
        foreach ($field in @('length', 'sha256', 'last_write_utc', 'attributes', 'sddl', 'posix_mode', 'uid', 'gid')) {
            if (-not (Test-FormalApplyFieldEqual -First $source -Second $preimage -Name $field)) {
                throw "[UPGRADE_APPLY_EVIDENCE_FAIL] Preimage seal disagrees with source for $($source.key) field=$field."
            }
        }
    }
}

function Assert-FormalApplyPackageContract {
    param($Layout, $PackageManifest)
    $managedLayout = @($Layout | Where-Object package_git_blob | Sort-Object git_path)
    $expected = @($managedLayout.git_path) + @('Backend/version.txt', 'Frontend/version.txt')
    Assert-FormalApplyKeySet -Name 'package' -Expected $expected -Actual @($PackageManifest.records.key)
    foreach ($record in @($PackageManifest.records | Where-Object { $_.key -in @('Backend/version.txt', 'Frontend/version.txt') })) {
        if ($record.git_blob -or ((Get-Content -LiteralPath $record.artifact_path -Raw -Encoding UTF8).Trim()) -cne $FormalPrepareTargetCommit.Substring(0, 7)) {
            throw "[UPGRADE_APPLY_EVIDENCE_FAIL] Package marker is invalid: $($record.key)"
        }
    }
    $artifactPaths = @()
    foreach ($layoutRecord in $managedLayout) {
        $record = Get-FormalApplyRecord -Manifest $PackageManifest -Key $layoutRecord.git_path
        if (-not ([string]$record.git_blob).Equals([string]$layoutRecord.package_git_blob, [StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_APPLY_EVIDENCE_FAIL] Package Git-object identity is invalid: $($record.key)"
        }
        $artifactPaths += [string]$record.artifact_path
    }
    $artifactBlobs = @(Get-GitOutput -Arguments (@('hash-object', '--') + $artifactPaths))
    if ($artifactBlobs.Count -ne $managedLayout.Count) {
        throw '[UPGRADE_APPLY_EVIDENCE_FAIL] Package artifact Git-object count is invalid.'
    }
    for ($index = 0; $index -lt $managedLayout.Count; $index++) {
        $record = Get-FormalApplyRecord -Manifest $PackageManifest -Key $managedLayout[$index].git_path
        if (-not ([string]$artifactBlobs[$index]).Trim().Equals([string]$record.git_blob, [StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_APPLY_EVIDENCE_FAIL] Package artifact differs from its ruled Git object: $($record.key)"
        }
    }
}

function Assert-FormalApplyObservationSafe {
    param([Parameter(Mandatory = $true)]$Observation)
    if ([bool](Get-OptionalProperty -Object $Observation -Name 'lock_exists' -Default $false) -or
        @(Get-OptionalProperty -Object $Observation -Name 'ui' -Default @()).Count -gt 0 -or
        @(Get-OptionalProperty -Object $Observation -Name 'daemon' -Default @()).Count -gt 0 -or
        @(Get-OptionalProperty -Object $Observation -Name 'workers' -Default @()).Count -gt 0) {
        throw '[UPGRADE_APPLY_RUNTIME_FAIL] Runtime or upgrade lock is active.'
    }
    foreach ($record in @(Get-OptionalProperty -Object $Observation -Name 'registry' -Default @())) {
        if ([bool](Get-OptionalProperty -Object $record -Name 'proc_exists' -Default $false) -or
            [bool](Get-OptionalProperty -Object $record -Name 'owned' -Default $false) -or
            [bool](Get-OptionalProperty -Object $record -Name 'ambiguous' -Default $false)) {
            throw '[UPGRADE_APPLY_RUNTIME_FAIL] Registry/process ownership is active or ambiguous.'
        }
    }
    foreach ($name in @('source_dirty', 'force_non_ancestor')) {
        if ([bool](Get-OptionalProperty -Object $Observation -Name $name -Default $false)) {
            throw "[UPGRADE_APPLY_RUNTIME_FAIL] Observation rejected: $name"
        }
    }
    foreach ($name in @('tracked_deletions', 'requirements_changes', 'protected_unreadable', 'ambiguous_runtime')) {
        if (@(Get-OptionalProperty -Object $Observation -Name $name -Default @()).Count -gt 0) {
            throw "[UPGRADE_APPLY_RUNTIME_FAIL] Observation rejected: $name"
        }
    }
}

function Invoke-FormalApplyValidationMode {
    param([Parameter(Mandatory = $true)]$Inputs)
    $result = New-FormalApplyValidationResult -Inputs $Inputs
    try {
        $fixtureMode = Test-FormalApplyFixtureMode -Inputs $Inputs
        $journalPath = Join-Path $Inputs.TransactionRoot 'transaction-journal.json'
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            throw '[UPGRADE_APPLY_TRANSACTION_FAIL] Explicit transaction journal is missing.'
        }
        try { $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
        catch { throw '[UPGRADE_APPLY_TRANSACTION_FAIL] Explicit transaction journal is unreadable or corrupt.' }
        Assert-FormalApplyTransactionIdentity -Inputs $Inputs -Journal $journal -FixtureMode $fixtureMode
        $result.transaction_id = [string]$journal.transaction_id
        $result.target_commit = [string]$journal.target_commit
        Add-FormalApplyCheck -Result $result -Id 'transaction' -Status 'pass' -TruthSource 'explicit root plus transaction-journal.json' -Reason 'Explicit transaction identity and prepared_pending_apply state agree.'

        $result.age_seconds = Get-FormalApplyTransactionAge -Journal $journal
        Add-FormalApplyCheck -Result $result -Id 'age' -Status 'pass' -TruthSource 'journal created_at_utc plus transaction ID' -Reason 'Prepared transaction is within the fixed 30-minute window.'

        Assert-FormalApplyNoCompetingTransaction -TransactionRoot $Inputs.TransactionRoot
        Add-FormalApplyCheck -Result $result -Id 'uniqueness' -Status 'pass' -TruthSource 'explicit transaction parent directory' -Reason 'No competing nonterminal transaction exists.'

        $script:FormalPrepareObservationPath = $Inputs.PreflightObservationPath
        $observation = Get-FormalPrepareObservation -Inputs $Inputs
        Assert-FormalApplyObservationSafe -Observation $observation

        $head = Get-HeadCommit
        if (-not ([string]$journal.repo_head).Equals($head, [StringComparison]::OrdinalIgnoreCase)) {
            throw "[UPGRADE_APPLY_REPO_FAIL] Prepared repo head $($journal.repo_head) differs from current head $head."
        }
        try { $layout = Resolve-MixedRepairLayout -Inputs $Inputs }
        catch { throw "[UPGRADE_APPLY_TARGET_FAIL] Current managed target shape is invalid. $($_.Exception.Message)" }
        Assert-FormalPrepareRepoBasis -FixtureMode $fixtureMode
        Add-FormalApplyCheck -Result $result -Id 'repository' -Status 'pass' -TruthSource 'Git branch, HEAD, origin/main, index, and working tree' -Reason 'Repository basis still matches the prepared transaction and authorized fixture dirt.'

        $sourceManifest = Read-FormalApplyManifest -TransactionRoot $Inputs.TransactionRoot -Name 'source' -Reference $journal.manifests.source
        $preimageManifest = Read-FormalApplyManifest -TransactionRoot $Inputs.TransactionRoot -Name 'preimage' -Reference $journal.manifests.preimage
        $packageManifest = Read-FormalApplyManifest -TransactionRoot $Inputs.TransactionRoot -Name 'package' -Reference $journal.manifests.package
        $expectedSource = @($layout | ForEach-Object { "$($_.side)/$($_.relative_path)" }) + @('Frontend/version.txt', 'Backend/version.txt', 'Frontend/sentry_config.ini', 'Backend/data/projects.json', 'Runtime/observation.json')
        Assert-FormalApplyKeySet -Name 'source' -Expected $expectedSource -Actual @($sourceManifest.records.key)
        Assert-FormalApplyPreimageContract -SourceManifest $sourceManifest -PreimageManifest $preimageManifest
        Assert-FormalApplyPackageContract -Layout $layout -PackageManifest $packageManifest
        Add-FormalApplyCheck -Result $result -Id 'evidence' -Status 'pass' -TruthSource 'sealed manifests, artifact hashes, and Git object IDs' -Reason 'Journal, manifests, preimage, and package evidence are complete and canonical.'

        $snapshot = Get-FormalPrepareSourceSnapshot -Inputs $Inputs -Layout $layout -Observation $observation
        $freshSource = New-FormalPrepareManifest -Type 'source' -Records (Get-FormalPrepareSourceManifestRecords -Inputs $Inputs -Snapshot $snapshot -Observation $observation -FixtureMode $fixtureMode)
        Assert-FormalApplySourceCurrent -SourceManifest $sourceManifest -FreshManifest $freshSource
        if ($snapshot.target_inventory_id -ne [string]$journal.target_inventory_id -or
            $snapshot.software_state_id -ne [string]$journal.software_state_id -or
            $snapshot.evidence_state_id -ne [string]$journal.evidence_state_id) {
            throw '[UPGRADE_APPLY_TARGET_FAIL] Current target/evidence state IDs differ from the prepared journal.'
        }
        Add-FormalApplyCheck -Result $result -Id 'targets' -Status 'pass' -TruthSource 'fresh target snapshot versus sealed source manifest' -Reason 'Managed targets and protected data still match the prepared state.'
        Add-FormalApplyCheck -Result $result -Id 'metadata' -Status 'pass' -TruthSource 'fresh ACL, attributes, and POSIX metadata' -Reason 'Target metadata still matches the prepared evidence.'
        Add-FormalApplyCheck -Result $result -Id 'runtime' -Status 'pass' -TruthSource 'fresh process, registry, worker, lock, and source observation' -Reason 'Runtime remains quiescent and unambiguous.'

        $result.result = 'eligible'
        $result.eligible = $true
        return $result
    }
    catch {
        return New-FormalApplyValidationFailureResult -Inputs $Inputs -Message $_.Exception.Message -Result $result
    }
}

# =========================
# Strict-TEMP install/recovery drill（假環境安裝與還原演練）
# =========================

function Assert-FormalApplyFixtureBoundary {
    param([Parameter(Mandatory = $true)]$Inputs)
    if (-not (Test-FormalApplyFixtureMode -Inputs $Inputs)) {
        throw '[UPGRADE_APPLY_FIXTURE_BOUNDARY_FAIL] Fixture apply/recovery requires IsolationRoot and fixture observation.'
    }
    try { Assert-FormalApplyValidationBoundary -Inputs $Inputs }
    catch { throw "[UPGRADE_APPLY_FIXTURE_BOUNDARY_FAIL] $($_.Exception.Message)" }
}

function Get-FormalApplyExecutionScope {
    param([Parameter(Mandatory = $true)]$Inputs)
    if (Test-FormalApplyFixtureMode -Inputs $Inputs) { return 'fixture' }
    return 'formal'
}

function Get-FormalApplyExecutionLockPath {
    param([Parameter(Mandatory = $true)]$Inputs)
    if (Test-FormalApplyFixtureMode -Inputs $Inputs) {
        return Join-Path $Inputs.IsolationRoot 'formal-upgrade.lock'
    }
    return Get-NormalizedFullPath $FormalApplyLockPath
}

function Assert-FormalApplyExecutionBoundary {
    param([Parameter(Mandatory = $true)]$Inputs)
    $fixtureMode = Test-FormalApplyFixtureMode -Inputs $Inputs
    if ($fixtureMode) {
        Assert-FormalApplyFixtureBoundary -Inputs $Inputs
        $lockPath = Get-FormalApplyExecutionLockPath -Inputs $Inputs
        if (-not (Test-StrictPathInside -Candidate $lockPath -Container $Inputs.IsolationRoot)) {
            throw '[UPGRADE_APPLY_FIXTURE_BOUNDARY_FAIL] Fixture upgrade lock escaped IsolationRoot.'
        }
        return
    }

    if ($Inputs.Mode -notin @('ApplyFormalInternal', 'RecoverFormalInternal')) {
        throw '[UPGRADE_APPLY_BOUNDARY_FAIL] A formal write scope requires an internal formal mode.'
    }
    if ($Inputs.IsolationRoot -or $Inputs.PreflightObservationPath) {
        throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Internal formal modes never accept a fixture seam or observation override.'
    }
    if (-not (Test-PathsEqual -First $Inputs.FrontendTarget -Second $FormalFrontendTarget) -or
        -not (Test-PathsEqual -First $Inputs.BackendTarget -Second $FormalBackendTarget)) {
        throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Internal formal modes accept only the fixed Windows and WSL targets.'
    }
    if (-not $Inputs.TransactionRoot -or
        -not (Test-StrictPathInside -Candidate $Inputs.TransactionRoot -Container $FormalPrepareTransactionsParent) -or
        -not (Test-PathsEqual -First (Split-Path -Parent $Inputs.TransactionRoot) -Second $FormalPrepareTransactionsParent)) {
        throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Internal formal mode requires one direct child of the fixed transaction parent.'
    }
    foreach ($path in @($FormalFrontendTarget, $FormalBackendTarget, $FormalPrepareTransactionsParent, $Inputs.TransactionRoot, $FormalApplyLockPath)) {
        Assert-FormalPrepareNoReparse -Path $path
    }
    foreach ($target in @($Inputs.FrontendTarget, $Inputs.BackendTarget)) {
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            throw "[UPGRADE_APPLY_BOUNDARY_FAIL] Fixed formal target is missing: $target"
        }
        if (Test-PathsOverlap -First $Inputs.TransactionRoot -Second $target) {
            throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Formal target and transaction trees overlap.'
        }
    }
    $observation = Get-LivePreflightObservation -Inputs $Inputs
    Assert-FormalPrepareAclAndOwner -Path $FormalPrepareTransactionsParent -Observation $observation -FixtureMode $false
    Assert-FormalPrepareAclAndOwner -Path $FormalFrontendTarget -Observation $observation -FixtureMode $false
}

function Read-FormalApplyFixtureJournal {
    param([Parameter(Mandatory = $true)]$Inputs)
    $fixtureMode = Test-FormalApplyFixtureMode -Inputs $Inputs
    $journalPath = Join-Path $Inputs.TransactionRoot 'transaction-journal.json'
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        throw '[UPGRADE_APPLY_FIXTURE_TRANSACTION_FAIL] Fixture transaction journal is missing.'
    }
    try { $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw '[UPGRADE_APPLY_FIXTURE_TRANSACTION_FAIL] Fixture transaction journal is unreadable or corrupt.' }
    if ($journal.schema -ne $FormalPrepareSchema -or
        [bool](Get-OptionalProperty -Object $journal -Name 'fixture_mode' -Default $false) -ne $fixtureMode) {
        throw '[UPGRADE_APPLY_FIXTURE_TRANSACTION_FAIL] Prepared journal scope disagrees with the selected execution mode.'
    }
    if (-not (Test-PathsEqual -First $journalPath -Second (Join-Path ([string]$journal.transaction_root) 'transaction-journal.json')) -or
        -not (Test-PathsEqual -First $Inputs.TransactionRoot -Second ([string]$journal.transaction_root)) -or
        -not (Test-PathsEqual -First $Inputs.FrontendTarget -Second ([string]$journal.targets.frontend)) -or
        -not (Test-PathsEqual -First $Inputs.BackendTarget -Second ([string]$journal.targets.backend))) {
        throw '[UPGRADE_APPLY_FIXTURE_TRANSACTION_FAIL] Journal identity or fixture targets disagree with explicit inputs.'
    }
    return [pscustomobject]@{ Path = $journalPath; Journal = $journal }
}

function Save-FormalApplyFixtureJournal {
    param([Parameter(Mandatory = $true)][string]$JournalPath, [Parameter(Mandatory = $true)]$Journal)
    $Journal.updated_at_utc = [DateTime]::UtcNow.ToString('o')
    Save-MixedRepairJournal -JournalPath $JournalPath -Journal $Journal
}

function New-FormalApplyExecutionLock {
    param([Parameter(Mandatory = $true)]$Inputs, [Parameter(Mandatory = $true)][string]$TransactionId)
    $path = Get-FormalApplyExecutionLockPath -Inputs $Inputs
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw '[UPGRADE_APPLY_LOCK_FAIL] Upgrade-lock parent must already exist.'
    }
    $stream = $null
    try {
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        $stream.SetLength(0)
        $bytes = [Text.Encoding]::UTF8.GetBytes($TransactionId)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        return [pscustomobject]@{ Path = $path; Stream = $stream }
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw "[UPGRADE_APPLY_LOCK_FAIL] Another upgrade owns the single upgrade lock: $path"
    }
}

function Close-FormalApplyExecutionLock {
    param($Lock)
    if ($null -eq $Lock) { return }
    $Lock.Stream.Dispose()
}

function Get-FormalApplyExecutionObservation {
    param([Parameter(Mandatory = $true)]$Inputs, [Parameter(Mandatory = $true)][string]$Checkpoint)
    $observation = if (Test-FormalApplyFixtureMode -Inputs $Inputs) {
        Read-PreflightFixtureObservation -Path $Inputs.PreflightObservationPath
    }
    else { Get-LivePreflightObservation -Inputs $Inputs }
    $injection = @{
        'after-upgrade-lock' = 'RuntimeAfterUpgradeLock'
        'before-first-target-write' = 'RuntimeBeforeFirstWrite'
        'before-version-markers' = 'RuntimeBeforeMarkers'
    }[$Checkpoint]
    if ($injection -and $FormalApplyFailureInjection -eq $injection) {
        $observation.ui = @([pscustomobject]@{ pid = 99999; owned = $true; ambiguous = $false; injected = $Checkpoint })
    }
    return $observation
}

function Assert-FormalApplyRuntimeCheckpoint {
    param($Inputs, $Journal, [string]$JournalPath, [string]$Checkpoint)
    $observation = Get-FormalApplyExecutionObservation -Inputs $Inputs -Checkpoint $Checkpoint
    Assert-FormalApplyObservationSafe -Observation $observation
    $Journal.fixture_apply.runtime_checkpoints += $Checkpoint
    $Journal.fixture_apply.events += "runtime-safe:$Checkpoint"
    Save-FormalApplyFixtureJournal -JournalPath $JournalPath -Journal $Journal
}

function Assert-FormalApplyJournalDurableBeforeWrite {
    param($Journal, [string]$JournalPath, [string]$ExpectedState)
    Save-FormalApplyFixtureJournal -JournalPath $JournalPath -Journal $Journal
    if ($FormalApplyFailureInjection -eq 'JournalDurabilityBeforeFirstWrite') {
        throw '[UPGRADE_APPLY_JOURNAL_FAIL] Injected durability failure before the first target write.'
    }
    try { $persisted = Get-Content -LiteralPath $JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw '[UPGRADE_APPLY_JOURNAL_FAIL] Applying journal could not be reread after durable flush.' }
    if ([string]$persisted.state -ne $ExpectedState -or
        [string]$persisted.fixture_apply.execution_scope -ne [string]$Journal.fixture_apply.execution_scope -or
        $null -ne $persisted.fixture_apply.current_operation) {
        throw '[UPGRADE_APPLY_JOURNAL_FAIL] Applying journal did not durably preserve the pre-write state.'
    }
    $Journal.fixture_apply.journal_durable_before_first_write = $true
    $Journal.fixture_apply.events += 'journal-durable-before-first-target-write'
    Save-FormalApplyFixtureJournal -JournalPath $JournalPath -Journal $Journal
}

function Get-FormalApplyFixtureResultName {
    param([string]$State)
    switch ($State) {
        'installed_pending_acceptance' { return 'installed_pending_acceptance' }
        'rolled_back' { return 'rolled_back' }
        'rolled_back_after_failure' { return 'rolled_back' }
        'indeterminate' { return 'indeterminate' }
        'rollback_failed' { return 'rollback_failed' }
        default { return 'interrupted' }
    }
}

function ConvertTo-FormalApplyFixtureResult {
    param([Parameter(Mandatory = $true)]$Journal, [string]$Message)
    $fixture = Get-OptionalProperty -Object $Journal -Name 'fixture_apply' -Default $null
    return [pscustomobject]@{
        schema = $FormalApplyExecutionSchema
        mode = [string](Get-OptionalProperty -Object $fixture -Name 'invocation_mode' -Default 'ApplyFormalFixture')
        execution_scope = [string](Get-OptionalProperty -Object $fixture -Name 'execution_scope' -Default 'fixture')
        result = Get-FormalApplyFixtureResultName -State ([string]$Journal.state)
        state = [string]$Journal.state
        transaction_id = [string]$Journal.transaction_id
        transaction_root = [string]$Journal.transaction_root
        target_commit = [string]$Journal.target_commit
        fixture_target_write_count = [int](Get-OptionalProperty -Object $fixture -Name 'fixture_target_write_count' -Default 0)
        formal_target_write_count = [int](Get-OptionalProperty -Object $fixture -Name 'formal_target_write_count' -Default 0)
        upgrade_lock_path = Get-OptionalProperty -Object $fixture -Name 'upgrade_lock_path' -Default $null
        runtime_checkpoints = @(Get-OptionalProperty -Object $fixture -Name 'runtime_checkpoints' -Default @())
        journal_durable_before_first_write = [bool](Get-OptionalProperty -Object $fixture -Name 'journal_durable_before_first_write' -Default $false)
        metadata_contract = Get-OptionalProperty -Object $fixture -Name 'metadata_contract' -Default $null
        write_order = @(Get-OptionalProperty -Object $fixture -Name 'write_order' -Default @())
        marker_order = @(Get-OptionalProperty -Object $fixture -Name 'marker_order' -Default @())
        events = @(Get-OptionalProperty -Object $fixture -Name 'events' -Default @())
        failure_tag = Get-OptionalProperty -Object $fixture -Name 'failure_tag' -Default $null
        message = $Message
    }
}

function New-FormalApplyFixtureFailureResult {
    param($Inputs, [Parameter(Mandatory = $true)][string]$Message)
    if ($Inputs -and $Inputs.TransactionRoot) {
        try {
            $entry = Read-FormalApplyFixtureJournal -Inputs $Inputs
            return ConvertTo-FormalApplyFixtureResult -Journal $entry.Journal -Message $Message
        }
        catch { }
    }
    return [pscustomobject]@{
        schema = $FormalApplyExecutionSchema
        mode = if ($Inputs) { [string]$Inputs.Mode } else { [string]$Mode }
        result = 'indeterminate'
        state = 'indeterminate'
        transaction_id = $null
        transaction_root = if ($Inputs) { $Inputs.TransactionRoot } else { $TransactionRoot }
        target_commit = $null
        fixture_target_write_count = 0
        formal_target_write_count = 0
        upgrade_lock_path = $null
        runtime_checkpoints = @()
        journal_durable_before_first_write = $false
        metadata_contract = $null
        write_order = @()
        marker_order = @()
        events = @()
        failure_tag = '[UPGRADE_APPLY_FIXTURE_FAIL]'
        message = $Message
    }
}

function Get-FormalApplyFixtureManifests {
    param([Parameter(Mandatory = $true)]$Journal)
    $root = [string]$Journal.transaction_root
    return [pscustomobject]@{
        Source = Read-FormalApplyManifest -TransactionRoot $root -Name 'source' -Reference $Journal.manifests.source
        Preimage = Read-FormalApplyManifest -TransactionRoot $root -Name 'preimage' -Reference $Journal.manifests.preimage
        Package = Read-FormalApplyManifest -TransactionRoot $root -Name 'package' -Reference $Journal.manifests.package
    }
}

function Get-FormalApplyFixturePackageRecord {
    param($PackageManifest, [string]$Key)
    $records = @($PackageManifest.records | Where-Object { $_.key -ceq $Key })
    if ($records.Count -gt 1) { throw "[UPGRADE_APPLY_FIXTURE_EVIDENCE_FAIL] Duplicate package record: $Key" }
    if ($records.Count -eq 1) { return $records[0] }
    return $null
}

function New-FormalApplyFixtureActionRecord {
    param($SourceRecord, $PreimageRecord, $PackageRecord, [string]$TransactionId, [bool]$Marker, [string]$ExecutionScope)
    $action = if ($PackageRecord) {
        if (-not [bool]$SourceRecord.exists) { 'add' }
        elseif ([string]$SourceRecord.sha256 -eq [string]$PackageRecord.artifact_sha256) { 'verify_unchanged' }
        else { 'replace' }
    }
    elseif ([bool]$SourceRecord.exists) { 'delete' }
    else { throw "[UPGRADE_APPLY_FIXTURE_EVIDENCE_FAIL] Neither preimage nor package exists for $($SourceRecord.key)." }
    $packagePath = if ($PackageRecord) { [string]$PackageRecord.artifact_path } else { $null }
    $packageItem = if ($packagePath) { Get-Item -LiteralPath $packagePath -Force -ErrorAction Stop } else { $null }
    return [pscustomobject][ordered]@{
        key = [string]$SourceRecord.key
        side = ([string]$SourceRecord.key).Split('/')[0]
        execution_scope = $ExecutionScope
        action = $action
        marker = $Marker
        target_path = [string]$SourceRecord.source_path
        existed_before = [bool]$SourceRecord.exists
        preimage_path = [string]$PreimageRecord.artifact_path
        preimage_sha256 = [string]$SourceRecord.sha256
        source_last_write_utc = $SourceRecord.last_write_utc
        source_attributes = $SourceRecord.attributes
        source_sddl = $SourceRecord.sddl
        source_posix_mode = $SourceRecord.posix_mode
        source_uid = $SourceRecord.uid
        source_gid = $SourceRecord.gid
        package_path = $packagePath
        package_sha256 = if ($PackageRecord) { [string]$PackageRecord.artifact_sha256 } else { $null }
        package_last_write_utc = if ($packageItem) { $packageItem.LastWriteTimeUtc.ToString('o') } else { $null }
        package_attributes = if ($packageItem) { $packageItem.Attributes.ToString() } else { $null }
        temp_path = "$($SourceRecord.source_path).$TransactionId.tmp"
        apply_state = if ($action -eq 'verify_unchanged') { 'verified_unchanged' } else { 'pending' }
        restore_state = 'pending'
    }
}

function New-FormalApplyFixturePlan {
    param([Parameter(Mandatory = $true)]$Inputs, [Parameter(Mandatory = $true)]$Journal, [Parameter(Mandatory = $true)]$Manifests)
    $executionScope = Get-FormalApplyExecutionScope -Inputs $Inputs
    $markerKeys = @('Backend/version.txt', 'Frontend/version.txt')
    $protectedKeys = @('Frontend/sentry_config.ini', 'Backend/data/projects.json')
    $managed = @($Manifests.Source.records | Where-Object { $_.key -ne 'Runtime/observation.json' -and $_.key -notin $markerKeys -and $_.key -notin $protectedKeys } |
        Sort-Object @{ Expression = { if ($_.key -like 'Frontend/*') { 0 } else { 1 } } }, key)
    $files = @()
    foreach ($source in $managed) {
        $preimage = Get-FormalApplyRecord -Manifest $Manifests.Preimage -Key $source.key
        $package = Get-FormalApplyFixturePackageRecord -PackageManifest $Manifests.Package -Key $source.key
        $files += New-FormalApplyFixtureActionRecord -SourceRecord $source -PreimageRecord $preimage -PackageRecord $package -TransactionId $Journal.transaction_id -Marker $false -ExecutionScope $executionScope
    }
    $markers = @()
    foreach ($key in $markerKeys) {
        $source = Get-FormalApplyRecord -Manifest $Manifests.Source -Key $key
        $preimage = Get-FormalApplyRecord -Manifest $Manifests.Preimage -Key $key
        $package = Get-FormalApplyRecord -Manifest $Manifests.Package -Key $key
        $markers += New-FormalApplyFixtureActionRecord -SourceRecord $source -PreimageRecord $preimage -PackageRecord $package -TransactionId $Journal.transaction_id -Marker $true -ExecutionScope $executionScope
    }
    $protected = @()
    foreach ($key in $protectedKeys) {
        $source = Get-FormalApplyRecord -Manifest $Manifests.Source -Key $key
        $protected += [pscustomobject][ordered]@{
            key = $key; side = ([string]$key).Split('/')[0]; execution_scope = $executionScope; target_path = [string]$source.source_path; existed_before = [bool]$source.exists
            sha256 = [string]$source.sha256; last_write_utc = $source.last_write_utc; attributes = $source.attributes
            sddl = $source.sddl; posix_mode = $source.posix_mode; uid = $source.uid; gid = $source.gid
        }
    }
    if ($executionScope -eq 'formal') {
        foreach ($record in @($files) + @($markers)) {
            if ($record.side -eq 'Backend' -and $record.action -eq 'add' -and
                ($null -eq $record.source_posix_mode -or $null -eq $record.source_uid -or $null -eq $record.source_gid)) {
                throw "[UPGRADE_APPLY_METADATA_FAIL] Backend add lacks a sealed POSIX identity contract: $($record.key)"
            }
        }
    }
    return [pscustomobject][ordered]@{
        schema = $FormalApplyExecutionSchema
        invocation_mode = [string]$Inputs.Mode
        execution_scope = $executionScope
        upgrade_lock_path = Get-FormalApplyExecutionLockPath -Inputs $Inputs
        files = $files
        markers = $markers
        protected = $protected
        current_operation = $null
        fixture_target_write_count = 0
        formal_target_write_count = 0
        runtime_checkpoints = @()
        journal_durable_before_first_write = $false
        metadata_contract = [pscustomobject][ordered]@{
            windows = 'content+existence+mtime+attributes+sddl'
            wsl = 'content+existence+mtime+uid+gid+mode'
            protected = 'observe-only-never-restored'
        }
        write_order = @()
        marker_order = @()
        events = @("$executionScope-plan-derived-from-preimage-and-package")
        failure_tag = $null
        error = $null
    }
}

function Test-FormalApplyFixtureMetadata {
    param([string]$Path, $LastWriteUtc, $Attributes)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if ($LastWriteUtc -and $item.LastWriteTimeUtc.ToString('o') -ne [string]$LastWriteUtc) { return $false }
    if ($Attributes -and $item.Attributes.ToString() -ne [string]$Attributes) { return $false }
    return $true
}

function Set-FormalApplyFixtureMetadata {
    param([string]$Path, $LastWriteUtc, $Attributes)
    if ($LastWriteUtc) {
        [IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::Parse([string]$LastWriteUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind))
    }
    if ($Attributes) {
        [IO.File]::SetAttributes($Path, [Enum]::Parse([IO.FileAttributes], [string]$Attributes))
    }
}

function Get-FormalApplyBackendLinuxPath {
    param([Parameter(Mandatory = $true)][string]$TargetPath)
    if (-not (Test-StrictPathInside -Candidate $TargetPath -Container $FormalBackendTarget)) {
        throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Backend metadata target escaped the fixed WSL root.'
    }
    $relative = (Get-NormalizedFullPath $TargetPath).Substring((Get-NormalizedFullPath $FormalBackendTarget).Length).TrimStart('\', '/').Replace('\', '/')
    return '/home/serpal/.laplace_sentry_backend/' + $relative
}

function Set-FormalApplyExecutionIdentity {
    param([Parameter(Mandatory = $true)]$Record)
    if ([string]$Record.execution_scope -ne 'formal' -or -not [bool]$Record.existed_before) { return }
    if ($Record.side -eq 'Frontend' -and $Record.source_sddl) {
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetSecurityDescriptorSddlForm([string]$Record.source_sddl)
        Set-Acl -LiteralPath $Record.target_path -AclObject $acl -ErrorAction Stop
        return
    }
    if ($Record.side -eq 'Backend') {
        if ($null -eq $Record.source_posix_mode -or $null -eq $Record.source_uid -or $null -eq $Record.source_gid) {
            throw "[UPGRADE_APPLY_METADATA_FAIL] Sealed POSIX identity is incomplete: $($Record.key)"
        }
        $linuxPath = Get-FormalApplyBackendLinuxPath -TargetPath $Record.target_path
        & wsl.exe -d Ubuntu --exec chown "$($Record.source_uid):$($Record.source_gid)" -- $linuxPath 2>$null
        if ($LASTEXITCODE -ne 0) { throw "[UPGRADE_APPLY_METADATA_FAIL] chown failed: $($Record.key)" }
        & wsl.exe -d Ubuntu --exec chmod ([string]$Record.source_posix_mode) -- $linuxPath 2>$null
        if ($LASTEXITCODE -ne 0) { throw "[UPGRADE_APPLY_METADATA_FAIL] chmod failed: $($Record.key)" }
    }
}

function Test-FormalApplyExecutionIdentity {
    param([Parameter(Mandatory = $true)]$Record)
    if ([string]$Record.execution_scope -ne 'formal' -or -not [bool]$Record.existed_before) { return $true }
    if ($Record.side -eq 'Frontend') {
        if (-not $Record.source_sddl) { return $false }
        return (Get-Acl -LiteralPath $Record.target_path -ErrorAction Stop).Sddl -ceq [string]$Record.source_sddl
    }
    if ($Record.side -eq 'Backend') {
        $metadata = Get-FormalPrepareWslFileMetadata -LinuxPath (Get-FormalApplyBackendLinuxPath -TargetPath $Record.target_path)
        return [string]$metadata.posix_mode -ceq [string]$Record.source_posix_mode -and
            [int]$metadata.uid -eq [int]$Record.source_uid -and [int]$metadata.gid -eq [int]$Record.source_gid
    }
    return $false
}

function Test-FormalApplyRecordMetadata {
    param([Parameter(Mandatory = $true)]$Record, [switch]$Applied)
    $mtime = if ($Applied) { $Record.package_last_write_utc } else { $Record.source_last_write_utc }
    $attributes = if ([string]$Record.execution_scope -eq 'formal' -and [bool]$Record.existed_before) {
        $Record.source_attributes
    }
    elseif ($Applied) { $Record.package_attributes } else { $Record.source_attributes }
    return (Test-FormalApplyFixtureMetadata -Path $Record.target_path -LastWriteUtc $mtime -Attributes $attributes) -and
        (Test-FormalApplyExecutionIdentity -Record $Record)
}

function Copy-FormalApplyFixtureFile {
    param($Record, [string]$TransactionId, [switch]$Restore)
    $source = if ($Restore) { [string]$Record.preimage_path } else { [string]$Record.package_path }
    $hash = if ($Restore) { [string]$Record.preimage_sha256 } else { [string]$Record.package_sha256 }
    $mtime = if ($Restore) { $Record.source_last_write_utc } else { $Record.package_last_write_utc }
    $attributes = if ([string]$Record.execution_scope -eq 'formal' -and [bool]$Record.existed_before) { $Record.source_attributes }
        elseif ($Restore) { $Record.source_attributes } else { $Record.package_attributes }
    $parent = Split-Path -Parent $Record.target_path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path -LiteralPath $Record.temp_path) { throw "[UPGRADE_APPLY_FIXTURE_INDETERMINATE] Unknown adjacent temp already exists: $($Record.temp_path)" }
    Copy-Item -LiteralPath $source -Destination $Record.temp_path -Force
    if (-not (Get-FileSha256 $Record.temp_path).Equals($hash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "[UPGRADE_APPLY_FIXTURE_EVIDENCE_FAIL] Temporary copy hash mismatch: $($Record.key)"
    }
    Move-Item -LiteralPath $Record.temp_path -Destination $Record.target_path -Force
    Set-FormalApplyFixtureMetadata -Path $Record.target_path -LastWriteUtc $mtime -Attributes $attributes
    Set-FormalApplyExecutionIdentity -Record $Record
    if (-not (Get-FileSha256 $Record.target_path).Equals($hash, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-FormalApplyRecordMetadata -Record $Record -Applied:(-not $Restore))) {
        throw "[UPGRADE_APPLY_FIXTURE_WRITE_FAIL] Installed content/metadata mismatch: $($Record.key)"
    }
}

function Get-FormalApplyFixtureDisposition {
    param($Record)
    $exists = Test-Path -LiteralPath $Record.target_path -PathType Leaf
    $hash = if ($exists) { Get-FileSha256 $Record.target_path } else { $null }
    $state = 'indeterminate'
    if ($Record.action -eq 'add') {
        if (-not $exists) { $state = 'preimage' }
        elseif ($hash.Equals([string]$Record.package_sha256, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-FormalApplyRecordMetadata -Record $Record -Applied)) { $state = 'applied' }
    }
    elseif ($Record.action -eq 'delete') {
        if (-not $exists) { $state = 'applied' }
        elseif ($hash.Equals([string]$Record.preimage_sha256, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-FormalApplyRecordMetadata -Record $Record)) { $state = 'preimage' }
    }
    elseif ($exists -and $hash.Equals([string]$Record.preimage_sha256, [StringComparison]::OrdinalIgnoreCase) -and
        $hash.Equals([string]$Record.package_sha256, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-FormalApplyRecordMetadata -Record $Record)) { $state = 'unchanged' }
    elseif ($exists -and $hash.Equals([string]$Record.preimage_sha256, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-FormalApplyRecordMetadata -Record $Record)) { $state = 'preimage' }
    elseif ($exists -and $hash.Equals([string]$Record.package_sha256, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-FormalApplyRecordMetadata -Record $Record -Applied)) { $state = 'applied' }

    $tempState = 'absent'
    if (Test-Path -LiteralPath $Record.temp_path -PathType Leaf) {
        $tempHash = Get-FileSha256 $Record.temp_path
        if ($Record.package_sha256 -and $tempHash.Equals([string]$Record.package_sha256, [StringComparison]::OrdinalIgnoreCase)) { $tempState = 'package' }
        elseif ($Record.preimage_sha256 -and $tempHash.Equals([string]$Record.preimage_sha256, [StringComparison]::OrdinalIgnoreCase)) { $tempState = 'preimage' }
        else { $tempState = 'indeterminate' }
    }
    return [pscustomobject]@{ state = $state; temp_state = $tempState }
}

function Assert-FormalApplyFixtureProtectedUnchanged {
    param([Parameter(Mandatory = $true)]$Journal)
    foreach ($record in $Journal.fixture_apply.protected) {
        $exists = Test-Path -LiteralPath $record.target_path -PathType Leaf
        if ([bool]$record.existed_before -ne $exists) { throw "[UPGRADE_APPLY_FIXTURE_PROTECTED_FAIL] Protected existence changed: $($record.key)" }
        if ($exists -and (-not (Get-FileSha256 $record.target_path).Equals([string]$record.sha256, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-FormalApplyFixtureMetadata -Path $record.target_path -LastWriteUtc $record.last_write_utc -Attributes $record.attributes))) {
            throw "[UPGRADE_APPLY_FIXTURE_PROTECTED_FAIL] Protected content or metadata changed: $($record.key)"
        }
        if ($exists -and [string]$record.execution_scope -eq 'formal') {
            if ($record.side -eq 'Frontend' -and ((Get-Acl -LiteralPath $record.target_path -ErrorAction Stop).Sddl -cne [string]$record.sddl)) {
                throw "[UPGRADE_APPLY_FIXTURE_PROTECTED_FAIL] Protected Windows identity changed: $($record.key)"
            }
            if ($record.side -eq 'Backend') {
                $metadata = Get-FormalPrepareWslFileMetadata -LinuxPath (Get-FormalApplyBackendLinuxPath -TargetPath $record.target_path)
                if ([string]$metadata.posix_mode -cne [string]$record.posix_mode -or
                    [int]$metadata.uid -ne [int]$record.uid -or [int]$metadata.gid -ne [int]$record.gid) {
                    throw "[UPGRADE_APPLY_FIXTURE_PROTECTED_FAIL] Protected WSL identity changed: $($record.key)"
                }
            }
        }
    }
}

function Assert-FormalApplyFixtureRecordBoundaries {
    param([Parameter(Mandatory = $true)]$Inputs, [Parameter(Mandatory = $true)]$Journal)
    if ($Journal.fixture_apply.schema -ne $FormalApplyExecutionSchema) { throw '[UPGRADE_APPLY_FIXTURE_TRANSACTION_FAIL] Formal apply execution schema is invalid.' }
    $expectedScope = Get-FormalApplyExecutionScope -Inputs $Inputs
    if ([string]$Journal.fixture_apply.execution_scope -ne $expectedScope -or
        -not (Test-PathsEqual -First ([string]$Journal.fixture_apply.upgrade_lock_path) -Second (Get-FormalApplyExecutionLockPath -Inputs $Inputs))) {
        throw '[UPGRADE_APPLY_FIXTURE_BOUNDARY_FAIL] Execution scope or single-lock path disagrees with the selected mode.'
    }
    foreach ($record in @($Journal.fixture_apply.files) + @($Journal.fixture_apply.markers)) {
        $root = if ($record.side -eq 'Frontend') { $Inputs.FrontendTarget } elseif ($record.side -eq 'Backend') { $Inputs.BackendTarget } else { throw '[UPGRADE_APPLY_FIXTURE_BOUNDARY_FAIL] Record side is invalid.' }
        $prefix = "$($record.side)/"
        if (-not ([string]$record.key).StartsWith($prefix, [StringComparison]::Ordinal)) { throw '[UPGRADE_APPLY_FIXTURE_BOUNDARY_FAIL] Record key/side identity is invalid.' }
        $expectedTarget = Join-Path $root ([string]$record.key).Substring($prefix.Length).Replace('/', '\')
        if (-not (Test-StrictPathInside -Candidate $record.target_path -Container $root) -or
            -not (Test-PathsEqual -First $record.target_path -Second $expectedTarget) -or
            -not (Test-PathsEqual -First $record.temp_path -Second "$($record.target_path).$($Journal.transaction_id).tmp")) {
            throw "[UPGRADE_APPLY_FIXTURE_BOUNDARY_FAIL] Target/temp escaped fake target: $($record.key)"
        }
        if ([string]$record.execution_scope -ne $expectedScope -or $record.action -notin @('verify_unchanged', 'replace', 'add', 'delete')) { throw '[UPGRADE_APPLY_FIXTURE_TRANSACTION_FAIL] Record scope/action is invalid.' }
        foreach ($path in @($record.preimage_path, $record.package_path)) {
            if ($path -and -not (Test-StrictPathInside -Candidate $path -Container $Inputs.TransactionRoot)) {
                throw "[UPGRADE_APPLY_FIXTURE_BOUNDARY_FAIL] Evidence escaped transaction: $path"
            }
        }
    }
    foreach ($record in $Journal.fixture_apply.protected) {
        if ([string]$record.execution_scope -ne $expectedScope) { throw '[UPGRADE_APPLY_FIXTURE_TRANSACTION_FAIL] Protected execution scope is invalid.' }
        $root = if ($record.key.StartsWith('Frontend/')) { $Inputs.FrontendTarget } else { $Inputs.BackendTarget }
        $side = ([string]$record.key).Split('/')[0]
        $expectedTarget = Join-Path $root ([string]$record.key).Substring($side.Length + 1).Replace('/', '\')
        if (-not (Test-StrictPathInside -Candidate $record.target_path -Container $root) -or
            -not (Test-PathsEqual -First $record.target_path -Second $expectedTarget)) { throw '[UPGRADE_APPLY_FIXTURE_BOUNDARY_FAIL] Protected path escaped its canonical fake target.' }
    }
}

function Assert-FormalApplyFixtureEvidenceIntegrity {
    param([Parameter(Mandatory = $true)]$Inputs, [Parameter(Mandatory = $true)]$Journal)
    $manifests = Get-FormalApplyFixtureManifests -Journal $Journal
    Assert-FormalApplyFixtureRecordBoundaries -Inputs $Inputs -Journal $Journal
    $allRecords = @($Journal.fixture_apply.files) + @($Journal.fixture_apply.markers)
    $allKeys = @($allRecords | ForEach-Object { [string]$_.key })
    if (@($allKeys | Group-Object | Where-Object Count -ne 1).Count -gt 0) { throw '[UPGRADE_APPLY_FIXTURE_EVIDENCE_FAIL] Fixture apply records contain duplicate keys.' }
    foreach ($record in $allRecords) {
        $source = Get-FormalApplyRecord -Manifest $manifests.Source -Key $record.key
        $preimage = Get-FormalApplyRecord -Manifest $manifests.Preimage -Key $record.key
        $package = Get-FormalApplyFixturePackageRecord -PackageManifest $manifests.Package -Key $record.key
        $expectedAction = if ($package) {
            if (-not [bool]$source.exists) { 'add' }
            elseif ([string]$source.sha256 -eq [string]$package.artifact_sha256) { 'verify_unchanged' }
            else { 'replace' }
        } elseif ([bool]$source.exists) { 'delete' } else { 'invalid' }
        $preimagePathEqual = if ($record.preimage_path -or $preimage.artifact_path) {
            $record.preimage_path -and $preimage.artifact_path -and (Test-PathsEqual -First $record.preimage_path -Second ([string]$preimage.artifact_path))
        } else { $true }
        if ($record.action -ne $expectedAction -or
            -not (Test-PathsEqual -First $record.target_path -Second ([string]$source.source_path)) -or
            -not $preimagePathEqual -or
            [bool]$record.existed_before -ne [bool]$source.exists -or
            [string]$record.preimage_sha256 -ne [string]$source.sha256 -or
            [string]$record.source_last_write_utc -ne [string]$source.last_write_utc -or
            [string]$record.source_attributes -ne [string]$source.attributes -or
            [string]$record.source_sddl -ne [string]$source.sddl -or
            [string]$record.source_posix_mode -ne [string]$source.posix_mode -or
            [string]$record.source_uid -ne [string]$source.uid -or
            [string]$record.source_gid -ne [string]$source.gid) {
            throw "[UPGRADE_APPLY_FIXTURE_EVIDENCE_FAIL] Journal action/preimage disagrees with sealed manifests: $($record.key)"
        }
        if ($package) {
            if (-not (Test-PathsEqual -First $record.package_path -Second ([string]$package.artifact_path)) -or
                [string]$record.package_sha256 -ne [string]$package.artifact_sha256) {
                throw "[UPGRADE_APPLY_FIXTURE_EVIDENCE_FAIL] Journal package disagrees with sealed manifest: $($record.key)"
            }
        }
        elseif ($record.package_path -or $record.package_sha256) { throw "[UPGRADE_APPLY_FIXTURE_EVIDENCE_FAIL] Delete record has unexpected package evidence: $($record.key)" }
        if ($record.existed_before -and (-not (Test-Path -LiteralPath $record.preimage_path -PathType Leaf) -or
            -not (Get-FileSha256 $record.preimage_path).Equals([string]$record.preimage_sha256, [StringComparison]::OrdinalIgnoreCase))) {
            throw "[UPGRADE_APPLY_FIXTURE_EVIDENCE_FAIL] Preimage evidence changed: $($record.key)"
        }
        if ($record.action -ne 'delete' -and (-not (Test-Path -LiteralPath $record.package_path -PathType Leaf) -or
            -not (Get-FileSha256 $record.package_path).Equals([string]$record.package_sha256, [StringComparison]::OrdinalIgnoreCase))) {
            throw "[UPGRADE_APPLY_FIXTURE_EVIDENCE_FAIL] Package evidence changed: $($record.key)"
        }
    }
    $protectedKeys = @($Journal.fixture_apply.protected | ForEach-Object { [string]$_.key } | Sort-Object)
    if (($protectedKeys -join ',') -cne 'Backend/data/projects.json,Frontend/sentry_config.ini') { throw '[UPGRADE_APPLY_FIXTURE_EVIDENCE_FAIL] Protected record set is invalid.' }
    foreach ($record in $Journal.fixture_apply.protected) {
        $source = Get-FormalApplyRecord -Manifest $manifests.Source -Key $record.key
        if (-not (Test-PathsEqual -First $record.target_path -Second ([string]$source.source_path)) -or
            [bool]$record.existed_before -ne [bool]$source.exists -or [string]$record.sha256 -ne [string]$source.sha256 -or
            [string]$record.sddl -ne [string]$source.sddl -or [string]$record.posix_mode -ne [string]$source.posix_mode -or
            [string]$record.uid -ne [string]$source.uid -or [string]$record.gid -ne [string]$source.gid) {
            throw "[UPGRADE_APPLY_FIXTURE_EVIDENCE_FAIL] Protected journal record disagrees with source manifest: $($record.key)"
        }
    }
}

function Set-FormalApplyFixtureFailureState {
    param($Journal, [string]$JournalPath, [string]$State, [string]$Tag, [string]$Message)
    $Journal.state = $State
    $Journal.result = Get-FormalApplyFixtureResultName -State $State
    $Journal.fixture_apply.failure_tag = $Tag
    $Journal.fixture_apply.error = $Message
    $Journal.fixture_apply.events += "$State`:$Tag"
    Save-FormalApplyFixtureJournal -JournalPath $JournalPath -Journal $Journal
}

function Invoke-FormalApplyFixtureRecordWrite {
    param($Journal, [string]$JournalPath, $Record, [string]$Phase)
    Assert-FormalApplyFixtureProtectedUnchanged -Journal $Journal
    $disposition = Get-FormalApplyFixtureDisposition -Record $Record
    if ($disposition.state -notin @('preimage', 'unchanged') -or $disposition.temp_state -ne 'absent') {
        throw "[UPGRADE_APPLY_FIXTURE_INDETERMINATE] $($Record.key) is not at its sealed preimage before apply."
    }
    if ($Record.action -eq 'verify_unchanged') { return $false }
    $Journal.fixture_apply.current_operation = [pscustomobject]@{ key = $Record.key; action = $Record.action; phase = 'before_write' }
    $Record.apply_state = 'writing'
    $Journal.fixture_apply.events += "before-write:$($Record.key)"
    Save-FormalApplyFixtureJournal -JournalPath $JournalPath -Journal $Journal

    if ($Record.action -eq 'delete') { Remove-Item -LiteralPath $Record.target_path -Force }
    else { Copy-FormalApplyFixtureFile -Record $Record -TransactionId $Journal.transaction_id }
    if ([string]$Journal.fixture_apply.execution_scope -eq 'formal') {
        $Journal.fixture_apply.formal_target_write_count = [int]$Journal.fixture_apply.formal_target_write_count + 1
    }
    else { $Journal.fixture_apply.fixture_target_write_count = [int]$Journal.fixture_apply.fixture_target_write_count + 1 }
    $Journal.fixture_apply.write_order += [string]$Record.key

    $firstManaged = @($Journal.fixture_apply.write_order | Where-Object { $_ -notin @('Backend/version.txt', 'Frontend/version.txt') }).Count -eq 1
    if ($Phase -eq 'managed' -and $firstManaged -and $FormalApplyFailureInjection -in @('AfterFirstManagedWriteBeforeRecord', 'AbruptAfterFirstManagedWriteBeforeRecord')) {
        $tag = if ($FormalApplyFailureInjection -eq 'AbruptAfterFirstManagedWriteBeforeRecord') { 'UPGRADE_APPLY_FIXTURE_ABRUPT' } else { 'UPGRADE_APPLY_FIXTURE_INJECTED_FAIL' }
        throw "[$tag] First managed write completed before its journal acknowledgement."
    }
    if ($Record.side -eq 'Backend' -and $Record.marker -and $FormalApplyFailureInjection -eq 'AfterBackendMarkerWriteBeforeRecord') { throw '[UPGRADE_APPLY_FIXTURE_INJECTED_FAIL] Backend marker write completed before journal acknowledgement.' }
    if ($Record.side -eq 'Frontend' -and $Record.marker -and $FormalApplyFailureInjection -eq 'AfterFrontendMarkerWriteBeforeRecord') { throw '[UPGRADE_APPLY_FIXTURE_INJECTED_FAIL] Frontend marker write completed before journal acknowledgement.' }

    $Record.apply_state = 'applied'
    $Journal.fixture_apply.current_operation = $null
    $Journal.fixture_apply.events += "applied:$($Record.key)"
    if ($Record.marker) { $Journal.fixture_apply.marker_order += [string]$Record.key }
    Save-FormalApplyFixtureJournal -JournalPath $JournalPath -Journal $Journal
    return $true
}

function Assert-FormalApplyFixtureInstalledState {
    param([Parameter(Mandatory = $true)]$Journal)
    foreach ($record in @($Journal.fixture_apply.files) + @($Journal.fixture_apply.markers)) {
        $state = (Get-FormalApplyFixtureDisposition -Record $record).state
        $expected = if ($record.action -eq 'verify_unchanged') { 'unchanged' } else { 'applied' }
        if ($state -ne $expected) { throw "[UPGRADE_APPLY_FIXTURE_POSTCHECK_FAIL] Installed state mismatch for $($record.key): $state" }
    }
    Assert-FormalApplyFixtureProtectedUnchanged -Journal $Journal
}

function Invoke-FormalApplyFixtureRollback {
    param([Parameter(Mandatory = $true)]$Inputs, [Parameter(Mandatory = $true)]$Journal, [Parameter(Mandatory = $true)][string]$JournalPath, [bool]$AfterFailure)
    try {
        Assert-FormalApplyFixtureEvidenceIntegrity -Inputs $Inputs -Journal $Journal
        Assert-FormalApplyFixtureProtectedUnchanged -Journal $Journal
        $records = @($Journal.fixture_apply.markers) + @($Journal.fixture_apply.files | Sort-Object key -Descending)
        $reconciled = @()
        foreach ($record in $records) {
            $disposition = Get-FormalApplyFixtureDisposition -Record $record
            if ($disposition.state -eq 'indeterminate' -or $disposition.temp_state -eq 'indeterminate') {
                throw "[UPGRADE_APPLY_FIXTURE_INDETERMINATE] Unknown target/temp content: $($record.key)"
            }
            $reconciled += [pscustomobject]@{ record = $record; disposition = $disposition }
        }
        if ($FormalApplyFailureInjection -eq 'RollbackBeforeFirstRestore' -and @($reconciled | Where-Object { $_.disposition.state -eq 'applied' }).Count -gt 0) {
            throw '[UPGRADE_APPLY_FIXTURE_ROLLBACK_FAIL] Injected rollback failure before the first restore.'
        }
        $Journal.state = 'rolling_back'
        $Journal.result = 'rolling_back'
        $Journal.fixture_apply.events += 'reconciled-from-current-targets'
        Save-FormalApplyFixtureJournal -JournalPath $JournalPath -Journal $Journal
        foreach ($entry in $reconciled) {
            $record = $entry.record
            if ($entry.disposition.temp_state -in @('package', 'preimage') -and (Test-Path -LiteralPath $record.temp_path)) { Remove-Item -LiteralPath $record.temp_path -Force }
            if ($entry.disposition.state -eq 'applied') {
                Assert-FormalApplyFixtureProtectedUnchanged -Journal $Journal
                $Journal.fixture_apply.current_operation = [pscustomobject]@{ key = $record.key; action = 'restore'; phase = 'before_write' }
                $Journal.fixture_apply.events += "before-restore:$($record.key)"
                Save-FormalApplyFixtureJournal -JournalPath $JournalPath -Journal $Journal
                if ($record.action -eq 'add') {
                    if (-not (Get-FileSha256 $record.target_path).Equals([string]$record.package_sha256, [StringComparison]::OrdinalIgnoreCase)) { throw "[UPGRADE_APPLY_FIXTURE_INDETERMINATE] Added file changed before restore: $($record.key)" }
                    Remove-Item -LiteralPath $record.target_path -Force
                }
                else { Copy-FormalApplyFixtureFile -Record $record -TransactionId $Journal.transaction_id -Restore }
                if ([string]$Journal.fixture_apply.execution_scope -eq 'formal') {
                    $Journal.fixture_apply.formal_target_write_count = [int]$Journal.fixture_apply.formal_target_write_count + 1
                }
                else { $Journal.fixture_apply.fixture_target_write_count = [int]$Journal.fixture_apply.fixture_target_write_count + 1 }
            }
            $record.restore_state = 'restored'
            $Journal.fixture_apply.current_operation = $null
            $Journal.fixture_apply.events += "restored:$($record.key)"
            Save-FormalApplyFixtureJournal -JournalPath $JournalPath -Journal $Journal
        }
        foreach ($record in $records) {
            $state = (Get-FormalApplyFixtureDisposition -Record $record).state
            if ($state -notin @('preimage', 'unchanged')) { throw "[UPGRADE_APPLY_FIXTURE_ROLLBACK_FAIL] Preimage was not restored: $($record.key) state=$state" }
        }
        Assert-FormalApplyFixtureProtectedUnchanged -Journal $Journal
        $Journal.state = if ($AfterFailure) { 'rolled_back_after_failure' } else { 'rolled_back' }
        $Journal.result = 'rolled_back'
        $Journal.fixture_apply.current_operation = $null
        $Journal.fixture_apply.events += [string]$Journal.state
        Save-FormalApplyFixtureJournal -JournalPath $JournalPath -Journal $Journal
        return $Journal
    }
    catch {
        $tag = if ($_.Exception.Message -match 'INDETERMINATE|PROTECTED|EVIDENCE|BOUNDARY|TRANSACTION') { '[UPGRADE_APPLY_FIXTURE_INDETERMINATE]' } else { '[UPGRADE_APPLY_FIXTURE_ROLLBACK_FAIL]' }
        $state = if ($tag -eq '[UPGRADE_APPLY_FIXTURE_INDETERMINATE]') { 'indeterminate' } else { 'rollback_failed' }
        Set-FormalApplyFixtureFailureState -Journal $Journal -JournalPath $JournalPath -State $state -Tag $tag -Message $_.Exception.Message
        return $Journal
    }
}

function Invoke-FormalApplyFixtureMode {
    param([Parameter(Mandatory = $true)]$Inputs)
    $validation = Invoke-FormalApplyValidationMode -Inputs $Inputs
    if (-not $validation.eligible) { throw "[UPGRADE_APPLY_FIXTURE_VALIDATION_FAIL] $(@($validation.failures.message) -join '; ')" }
    $entry = Read-FormalApplyFixtureJournal -Inputs $Inputs
    $journal = $entry.Journal
    $executionLock = $null
    try {
        $executionLock = New-FormalApplyExecutionLock -Inputs $Inputs -TransactionId ([string]$journal.transaction_id)
        $fixturePlan = New-FormalApplyFixturePlan -Inputs $Inputs -Journal $journal -Manifests (Get-FormalApplyFixtureManifests -Journal $journal)
        Add-Member -InputObject $journal -NotePropertyName fixture_apply -NotePropertyValue $fixturePlan -Force
        $journal.state = if ($fixturePlan.execution_scope -eq 'formal') { 'formal_apply_prepared' } else { 'fixture_apply_prepared' }
        $journal.result = [string]$journal.state
        $journal.fixture_apply.events += 'single-upgrade-lock-acquired'
        Save-FormalApplyFixtureJournal -JournalPath $entry.Path -Journal $journal
        Assert-FormalApplyRuntimeCheckpoint -Inputs $Inputs -Journal $journal -JournalPath $entry.Path -Checkpoint 'after-upgrade-lock'
        Assert-FormalApplyFixtureEvidenceIntegrity -Inputs $Inputs -Journal $journal
        Assert-FormalApplyFixtureProtectedUnchanged -Journal $journal
        $journal.state = if ($fixturePlan.execution_scope -eq 'formal') { 'applying_formal' } else { 'applying_fixture' }
        $journal.result = [string]$journal.state
        $journal.fixture_apply.events += 'applying-general-files'
        Assert-FormalApplyJournalDurableBeforeWrite -Journal $journal -JournalPath $entry.Path -ExpectedState ([string]$journal.state)
        Assert-FormalApplyRuntimeCheckpoint -Inputs $Inputs -Journal $journal -JournalPath $entry.Path -Checkpoint 'before-first-target-write'
        if ($FormalApplyFailureInjection -eq 'BeforeManagedWrites') { throw '[UPGRADE_APPLY_FIXTURE_INJECTED_FAIL] Failure before managed writes.' }

        foreach ($side in @('Frontend', 'Backend')) {
            foreach ($record in @($journal.fixture_apply.files | Where-Object side -eq $side)) {
                [void](Invoke-FormalApplyFixtureRecordWrite -Journal $journal -JournalPath $entry.Path -Record $record -Phase 'managed')
            }
            if ($side -eq 'Frontend' -and $FormalApplyFailureInjection -eq 'AfterFrontendManaged') { throw '[UPGRADE_APPLY_FIXTURE_INJECTED_FAIL] Failure after frontend managed phase.' }
            if ($side -eq 'Backend' -and $FormalApplyFailureInjection -eq 'AfterBackendManaged') { throw '[UPGRADE_APPLY_FIXTURE_INJECTED_FAIL] Failure after backend managed phase.' }
        }
        foreach ($record in $journal.fixture_apply.files) {
            $state = (Get-FormalApplyFixtureDisposition -Record $record).state
            if ($state -notin @('applied', 'unchanged')) { throw "[UPGRADE_APPLY_FIXTURE_POSTCHECK_FAIL] General file verification failed: $($record.key)" }
        }
        $journal.fixture_apply.events += 'all-general-files-verified-before-markers'
        Save-FormalApplyFixtureJournal -JournalPath $entry.Path -Journal $journal
        Assert-FormalApplyRuntimeCheckpoint -Inputs $Inputs -Journal $journal -JournalPath $entry.Path -Checkpoint 'before-version-markers'

        foreach ($record in $journal.fixture_apply.markers) {
            if ($record.side -eq 'Backend' -and $FormalApplyFailureInjection -eq 'BeforeBackendMarkerWrite') { throw '[UPGRADE_APPLY_FIXTURE_INJECTED_FAIL] Failure before backend marker.' }
            if ($record.side -eq 'Frontend' -and $FormalApplyFailureInjection -eq 'BeforeFrontendMarkerWrite') { throw '[UPGRADE_APPLY_FIXTURE_INJECTED_FAIL] Failure before frontend marker.' }
            [void](Invoke-FormalApplyFixtureRecordWrite -Journal $journal -JournalPath $entry.Path -Record $record -Phase 'marker')
        }
        if ($FormalApplyFailureInjection -eq 'AfterAllMarkers') { throw '[UPGRADE_APPLY_FIXTURE_INJECTED_FAIL] Failure after both markers before acceptance state.' }
        Assert-FormalApplyFixtureInstalledState -Journal $journal
        $journal.state = 'installed_pending_acceptance'
        $journal.result = 'installed_pending_acceptance'
        $journal.fixture_apply.events += 'installed_pending_acceptance'
        Save-FormalApplyFixtureJournal -JournalPath $entry.Path -Journal $journal
        $message = if ($fixturePlan.execution_scope -eq 'formal') {
            'The fixed formal targets contain the ruled package and await smoke testing/human acceptance.'
        }
        else { 'Fixture targets contain the ruled package and await human acceptance; no formal upgrade was performed.' }
        return ConvertTo-FormalApplyFixtureResult -Journal $journal -Message $message
    }
    catch {
        $applyError = $_.Exception.Message
        if ($null -eq (Get-OptionalProperty -Object $journal -Name 'fixture_apply' -Default $null)) { throw }
        if ($applyError -match '\[UPGRADE_APPLY_FIXTURE_ABRUPT\]') {
            return ConvertTo-FormalApplyFixtureResult -Journal $journal -Message $applyError
        }
        if ($applyError -match '\[UPGRADE_APPLY_RUNTIME_FAIL\]' -and
            ([int]$journal.fixture_apply.fixture_target_write_count + [int]$journal.fixture_apply.formal_target_write_count) -gt 0) {
            Set-FormalApplyFixtureFailureState -Journal $journal -JournalPath $entry.Path -State 'interrupted_runtime' -Tag '[UPGRADE_APPLY_RUNTIME_FAIL]' -Message $applyError
            return ConvertTo-FormalApplyFixtureResult -Journal $journal -Message 'Runtime reappeared after target writes; evidence is preserved for explicit recovery after quiescence.'
        }
        $journal.fixture_apply.failure_tag = '[UPGRADE_APPLY_FIXTURE_APPLY_FAIL]'
        $journal.fixture_apply.error = $applyError
        $journal.fixture_apply.events += "apply-failed:$applyError"
        Save-FormalApplyFixtureJournal -JournalPath $entry.Path -Journal $journal
        try { Assert-FormalApplyRuntimeCheckpoint -Inputs $Inputs -Journal $journal -JournalPath $entry.Path -Checkpoint 'before-rollback' }
        catch {
            Set-FormalApplyFixtureFailureState -Journal $journal -JournalPath $entry.Path -State 'interrupted_runtime' -Tag '[UPGRADE_APPLY_RUNTIME_FAIL]' -Message $_.Exception.Message
            return ConvertTo-FormalApplyFixtureResult -Journal $journal -Message 'Runtime became active before rollback; evidence is preserved without another target write.'
        }
        $journal = Invoke-FormalApplyFixtureRollback -Inputs $Inputs -Journal $journal -JournalPath $entry.Path -AfterFailure $true
        return ConvertTo-FormalApplyFixtureResult -Journal $journal -Message $applyError
    }
    finally { Close-FormalApplyExecutionLock -Lock $executionLock }
}

function Invoke-FormalApplyFixtureRecoveryMode {
    param([Parameter(Mandatory = $true)]$Inputs)
    $entry = Read-FormalApplyFixtureJournal -Inputs $Inputs
    $journal = $entry.Journal
    if ($null -eq (Get-OptionalProperty -Object $journal -Name 'fixture_apply' -Default $null)) {
        throw '[UPGRADE_APPLY_FIXTURE_TRANSACTION_FAIL] No fixture apply progress exists to recover.'
    }
    $journal.fixture_apply.invocation_mode = 'RecoverFormalFixture'
    if ($Inputs.Mode -eq 'RecoverFormalInternal') { $journal.fixture_apply.invocation_mode = 'RecoverFormalInternal' }
    if ($journal.state -in @('rolled_back', 'rolled_back_after_failure')) {
        return ConvertTo-FormalApplyFixtureResult -Journal $journal -Message 'Current targets already match the sealed preimage.'
    }
    if ($journal.state -in @('indeterminate', 'rollback_failed')) {
        return ConvertTo-FormalApplyFixtureResult -Journal $journal -Message 'Prior indeterminate/rollback-failed evidence is preserved; automatic retry is forbidden.'
    }
    if ($journal.state -eq 'installed_pending_acceptance') {
        return ConvertTo-FormalApplyFixtureResult -Journal $journal -Message 'Pending acceptance requires an explicit human disposition; automatic recovery did not alter the journal or targets.'
    }
    $executionLock = $null
    try {
        $executionLock = New-FormalApplyExecutionLock -Inputs $Inputs -TransactionId ([string]$journal.transaction_id)
        $journal.fixture_apply.events += 'single-upgrade-lock-acquired-for-recovery'
        Save-FormalApplyFixtureJournal -JournalPath $entry.Path -Journal $journal
        Assert-FormalApplyRuntimeCheckpoint -Inputs $Inputs -Journal $journal -JournalPath $entry.Path -Checkpoint 'after-upgrade-lock'
        Assert-FormalApplyRuntimeCheckpoint -Inputs $Inputs -Journal $journal -JournalPath $entry.Path -Checkpoint 'before-rollback'
        $journal = Invoke-FormalApplyFixtureRollback -Inputs $Inputs -Journal $journal -JournalPath $entry.Path -AfterFailure $false
        return ConvertTo-FormalApplyFixtureResult -Journal $journal -Message 'Recovery reconciled current target contents against sealed preimage/package evidence.'
    }
    finally { Close-FormalApplyExecutionLock -Lock $executionLock }
}

function Invoke-FormalApplyInternalMode {
    param([Parameter(Mandatory = $true)]$Inputs)
    if ((Get-FormalApplyExecutionScope -Inputs $Inputs) -ne 'formal') { throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Internal formal apply cannot enter fixture scope.' }
    return Invoke-FormalApplyFixtureMode -Inputs $Inputs
}

function Invoke-FormalApplyInternalRecoveryMode {
    param([Parameter(Mandatory = $true)]$Inputs)
    if ((Get-FormalApplyExecutionScope -Inputs $Inputs) -ne 'formal') { throw '[UPGRADE_APPLY_BOUNDARY_FAIL] Internal formal recovery cannot enter fixture scope.' }
    return Invoke-FormalApplyFixtureRecoveryMode -Inputs $Inputs
}
