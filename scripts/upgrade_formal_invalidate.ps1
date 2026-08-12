<#
.SYNOPSIS
使一筆已被裁決為舊目標的正式 prepare 交易失效，但不碰正式目標。
.DESCRIPTION
Purpose: append one stale-target invalidation to a selected prepared transaction.
Inputs: one fixed-formal transaction root; the ruled target comes only from upgrade_formal_prepare.ps1.
Outputs: stdout JSON derived from the updated transaction journal.
SSOT Output: transaction-journal.json; no parallel state file.
Exit codes: caller maps success to 0 and rejection to 9.
SKIP conditions: none.
FAIL conditions: fixture path, identity, state, hash, manifest, target, or lock checks fail.
Order-sensitive checks: lock, reread, identity and all sealed manifests are checked before journal mutation.
Side effects: writes only the selected formal transaction journal; never writes formal targets, runs apply, recovery, prepare, cleanup, or runtime actions.
#>
# 這支腳本在做什麼：把已裁決為舊 target 的 prepared transaction 留下不可重入的正式失效證據。
# 這支腳本不做什麼：不刪交易、不改 manifest、不改目標副本，也不提供 batch 公開入口。
# 常改區塊：失效證據欄位與 journal 完整性檢查。
# 不要亂動的區塊：固定交易根、共用升級鎖、零目標寫入與 append-only event。
Set-StrictMode -Version Latest
$FormalInvalidateSchema = 'laplace-formal-invalidate-v1'

function New-FormalInvalidateFailureResult {
    param($Inputs, [Parameter(Mandatory = $true)][string]$Message)
    return [pscustomobject]@{ schema = $FormalInvalidateSchema; mode = 'InvalidateFormalInternal'; result = 'rejected'; transaction_root = if ($Inputs) { $Inputs.TransactionRoot } else { $null }; formal_target_write_count = 0; error = $Message }
}

function Assert-FormalInvalidateInternalBoundary {
    param([Parameter(Mandatory = $true)]$Inputs)
    if (-not $Inputs.TransactionRoot) { throw '[UPGRADE_INVALIDATE_BOUNDARY_FAIL] InvalidateFormalInternal requires one explicit transaction directory.' }
    if ($Inputs.IsolationRoot -or $Inputs.PreflightObservationPath) { throw '[UPGRADE_INVALIDATE_BOUNDARY_FAIL] InvalidateFormalInternal rejects fixture inputs.' }
    if (-not (Test-PathsEqual -First $Inputs.FrontendTarget -Second $FormalFrontendTarget) -or -not (Test-PathsEqual -First $Inputs.BackendTarget -Second $FormalBackendTarget)) { throw '[UPGRADE_INVALIDATE_BOUNDARY_FAIL] Internal invalidation accepts only fixed formal targets.' }
    if (-not (Test-StrictPathInside -Candidate $Inputs.TransactionRoot -Container $FormalPrepareTransactionsParent)) { throw '[UPGRADE_INVALIDATE_BOUNDARY_FAIL] Transaction root must be a strict child of the fixed formal transaction parent.' }
    foreach ($path in @($FormalPrepareTransactionsParent, $Inputs.TransactionRoot, $FormalApplyLockPath)) { Assert-FormalPrepareNoReparse -Path $path }
    if (-not (Test-Path -LiteralPath $Inputs.TransactionRoot -PathType Container)) { throw '[UPGRADE_INVALIDATE_BOUNDARY_FAIL] Selected transaction directory is missing.' }
}

function Read-FormalInvalidateJournal {
    param([Parameter(Mandatory = $true)]$Inputs)
    $path = Join-Path $Inputs.TransactionRoot 'transaction-journal.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '[UPGRADE_INVALIDATE_TRANSACTION_FAIL] Transaction journal is missing.' }
    try { $journal = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { throw '[UPGRADE_INVALIDATE_TRANSACTION_FAIL] Transaction journal is unreadable.' }
    foreach ($field in @('schema','mode','state','result','transaction_id','transaction_root','transaction_parent','target_commit','manifests','formal_target_write_count')) { if ($null -eq $journal.PSObject.Properties[$field]) { throw "[UPGRADE_INVALIDATE_TRANSACTION_FAIL] Journal is missing required field: $field" } }
    if ($journal.schema -ne $FormalPrepareSchema -or $journal.mode -ne 'PrepareFormal' -or
        $journal.state -ne 'prepared_pending_apply' -or $journal.result -ne 'prepared' -or
        [int]$journal.formal_target_write_count -ne 0) {
        throw '[UPGRADE_INVALIDATE_TRANSACTION_FAIL] Journal is not an intact prepared zero-write transaction.'
    }
    if (-not (Test-PathsEqual -First $Inputs.TransactionRoot -Second ([string]$journal.transaction_root)) -or -not (Test-PathsEqual -First (Split-Path -Leaf $Inputs.TransactionRoot) -Second ([string]$journal.transaction_id)) -or -not (Test-PathsEqual -First (Split-Path -Parent $Inputs.TransactionRoot) -Second ([string]$journal.transaction_parent))) { throw '[UPGRADE_INVALIDATE_TRANSACTION_FAIL] Explicit transaction path and journal identity disagree.' }
    if ([bool](Get-OptionalProperty -Object $journal -Name 'fixture_mode' -Default $false)) { throw '[UPGRADE_INVALIDATE_TRANSACTION_FAIL] Formal internal invalidation rejects fixture journals.' }
    if ([string]$journal.target_commit -eq $FormalUpgradeTargetCommit) { throw '[UPGRADE_INVALIDATE_TARGET_MATCH] Selected transaction already names the ruled target commit.' }
    $hashes = [ordered]@{}
    foreach ($name in @('source','preimage','package')) { [void](Assert-FormalPrepareManifestIntegrity -TransactionRoot $Inputs.TransactionRoot -ManifestReference $journal.manifests.$name); $hashes[$name] = [string]$journal.manifests.$name.sha256 }
    return [pscustomobject]@{ Path = $path; Journal = $journal; ManifestHashes = [pscustomobject]$hashes }
}

function Assert-FormalInvalidatedJournal {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$BeforeHash)
    $journal = $Record.Journal
    if ($journal.state -ne 'invalidated' -or $journal.result -ne 'invalidated' -or @($journal.events | Where-Object { $_ -eq 'invalidated:stale_target_commit' }).Count -ne 1) { throw '[UPGRADE_INVALIDATE_RESULT_FAIL] Invalidated terminal state or event is missing.' }
    $inv = $journal.invalidation
    foreach ($field in @('reason_code','prior_state','prior_result','observed_target_commit','ruled_target_commit','invalidated_at_utc','invocation_mode','journal_sha256_before','manifest_sha256')) { if ($null -eq $inv.PSObject.Properties[$field]) { throw "[UPGRADE_INVALIDATE_RESULT_FAIL] Invalidation evidence is missing: $field" } }
    if ($inv.reason_code -ne 'stale_target_commit' -or $inv.prior_state -ne 'prepared_pending_apply' -or $inv.prior_result -ne 'prepared' -or $inv.observed_target_commit -eq $inv.ruled_target_commit -or $inv.ruled_target_commit -ne $FormalUpgradeTargetCommit -or $inv.invocation_mode -ne 'InvalidateFormalInternal' -or $inv.journal_sha256_before -ne $BeforeHash) { throw '[UPGRADE_INVALIDATE_RESULT_FAIL] Invalidation evidence is inconsistent.' }
    foreach ($name in @('source','preimage','package')) { if ([string]$inv.manifest_sha256.$name -ne [string]$Record.ManifestHashes.$name) { throw "[UPGRADE_INVALIDATE_RESULT_FAIL] Manifest hash evidence changed: $name" } }
    if ([int]$journal.formal_target_write_count -ne 0) { throw '[UPGRADE_INVALIDATE_RESULT_FAIL] Invalidation crossed the zero formal-write boundary.' }
}

function Invoke-FormalInvalidateInternalMode {
    param([Parameter(Mandatory = $true)]$Inputs)
    $lock = $null
    try {
        $initial = Read-FormalInvalidateJournal -Inputs $Inputs
        $lock = New-FormalApplyExecutionLock -Inputs $Inputs -TransactionId ([string]$initial.Journal.transaction_id)
        $record = Read-FormalInvalidateJournal -Inputs $Inputs
        $beforeHash = Get-FileSha256 $record.Path
        $journal = $record.Journal
        $journal.events = @($journal.events) + 'invalidated:stale_target_commit'
        $journal | Add-Member -NotePropertyName invalidation -NotePropertyValue ([pscustomobject][ordered]@{ reason_code='stale_target_commit'; prior_state=[string]$journal.state; prior_result=[string]$journal.result; observed_target_commit=[string]$journal.target_commit; ruled_target_commit=$FormalUpgradeTargetCommit; invalidated_at_utc=[DateTime]::UtcNow.ToString('o'); invocation_mode='InvalidateFormalInternal'; journal_sha256_before=$beforeHash; manifest_sha256=$record.ManifestHashes }) -Force
        $journal.state = 'invalidated'; $journal.result = 'invalidated'
        Save-MixedRepairJournal -JournalPath $record.Path -Journal $journal
        $after = [pscustomobject]@{ Path=$record.Path; Journal=(Get-Content -LiteralPath $record.Path -Raw -Encoding UTF8 | ConvertFrom-Json); ManifestHashes=$record.ManifestHashes }
        Assert-FormalInvalidatedJournal -Record $after -BeforeHash $beforeHash
        return [pscustomobject]@{ schema=$FormalInvalidateSchema; mode='InvalidateFormalInternal'; result='invalidated'; transaction_id=$after.Journal.transaction_id; transaction_root=$Inputs.TransactionRoot; formal_target_write_count=0; invalidation=$after.Journal.invalidation }
    }
    finally { Close-FormalApplyExecutionLock -Lock $lock }
}
