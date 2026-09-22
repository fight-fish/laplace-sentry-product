<#
.SYNOPSIS
使一筆已無合法續作路徑的正式 prepare 交易失效，但不碰正式目標。
.DESCRIPTION
Purpose: append one stale-target or expired-transaction invalidation to a selected prepared transaction.
Inputs: one fixed-formal transaction root; the ruled target comes only from upgrade_formal_prepare.ps1.
Outputs: stdout JSON derived from the updated transaction journal.
SSOT Output: transaction-journal.json; no parallel state file.
Exit codes: caller maps success to 0 and rejection to 9.
SKIP conditions: none.
FAIL conditions: fixture path, identity, state, hash, manifest, target, age, or lock checks fail.
Order-sensitive checks: lock, reread, identity, age and all sealed manifests are checked before journal mutation.
Side effects: writes only the selected formal transaction journal; never writes formal targets, runs apply, recovery, prepare, cleanup, or runtime actions.
Age rule: the fixed validation window lives only in upgrade_formal_apply.ps1; this script reuses that constant and parser and never defines a second limit.
#>
# 這支腳本在做什麼：對已無合法續作路徑的 prepared transaction 留下不可重入的正式失效證據。
# 兩條合法理由：target 已被裁決為舊（stale_target_commit），或同 target 但已逾固定驗票窗口（expired_transaction）。
# 這支腳本不做什麼：不刪交易、不改 manifest、不改目標副本，也不提供 batch 公開入口。
# 常改區塊：失效證據欄位與 journal 完整性檢查。
# 不要亂動的區塊：固定交易根、共用升級鎖、零目標寫入與 append-only event。
Set-StrictMode -Version Latest
$FormalInvalidateSchema = 'laplace-formal-invalidate-v1'

function Get-FormalInvalidateEvidenceAge {
    # 逾時判定、journal 落檔與寫後自驗必須共用同一個值，否則落在捨入邊界的交易會先寫成
    # invalidated、再因證據值回落而自驗失敗，留下已改狀態卻回報失敗的半套交易。
    # 正規化一律先於門檻比較，三位小數即證據精度本身，不是事後美化。
    param([Parameter(Mandatory = $true)][double]$RawAgeSeconds)
    return [double][Math]::Round($RawAgeSeconds, 3)
}

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
    # 失效理由只有兩條合法路徑：舊 target，或同 target 但已確實逾時而無法再走 Validate／Apply。
    # 同 target 且仍在窗口內者一律拒絕，避免繞過固定 30 分鐘驗票上限。
    $reasonCode = 'stale_target_commit'
    $ageSeconds = $null
    if ([string]$journal.target_commit -eq $FormalUpgradeTargetCommit) {
        if ($null -eq $journal.PSObject.Properties['created_at_utc']) { throw '[UPGRADE_INVALIDATE_TRANSACTION_FAIL] Journal is missing required field: created_at_utc' }
        $ageSeconds = Get-FormalInvalidateEvidenceAge -RawAgeSeconds (Get-FormalTransactionAgeSeconds -Journal $journal)
        if ($ageSeconds -le ($FormalApplyMaximumAgeMinutes * 60)) { throw '[UPGRADE_INVALIDATE_TARGET_MATCH] Selected transaction names the ruled target commit and is still inside the validation window.' }
        $reasonCode = 'expired_transaction'
    }
    $hashes = [ordered]@{}
    foreach ($name in @('source','preimage','package')) { [void](Assert-FormalPrepareManifestIntegrity -TransactionRoot $Inputs.TransactionRoot -ManifestReference $journal.manifests.$name); $hashes[$name] = [string]$journal.manifests.$name.sha256 }
    return [pscustomobject]@{ Path = $path; Journal = $journal; ManifestHashes = [pscustomobject]$hashes; ReasonCode = $reasonCode; AgeSeconds = $ageSeconds }
}

function Assert-FormalInvalidatedJournal {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$BeforeHash, [Parameter(Mandatory = $true)][string]$ReasonCode)
    $journal = $Record.Journal
    if ($journal.state -ne 'invalidated' -or $journal.result -ne 'invalidated' -or @($journal.events | Where-Object { $_ -eq "invalidated:$ReasonCode" }).Count -ne 1) { throw '[UPGRADE_INVALIDATE_RESULT_FAIL] Invalidated terminal state or event is missing.' }
    $inv = $journal.invalidation
    foreach ($field in @('reason_code','prior_state','prior_result','observed_target_commit','ruled_target_commit','invalidated_at_utc','invocation_mode','journal_sha256_before','manifest_sha256')) { if ($null -eq $inv.PSObject.Properties[$field]) { throw "[UPGRADE_INVALIDATE_RESULT_FAIL] Invalidation evidence is missing: $field" } }
    if ($inv.reason_code -ne $ReasonCode -or $inv.prior_state -ne 'prepared_pending_apply' -or $inv.prior_result -ne 'prepared' -or $inv.ruled_target_commit -ne $FormalUpgradeTargetCommit -or $inv.invocation_mode -ne 'InvalidateFormalInternal' -or $inv.journal_sha256_before -ne $BeforeHash) { throw '[UPGRADE_INVALIDATE_RESULT_FAIL] Invalidation evidence is inconsistent.' }
    if ($ReasonCode -eq 'stale_target_commit') {
        if ($inv.observed_target_commit -eq $inv.ruled_target_commit) { throw '[UPGRADE_INVALIDATE_RESULT_FAIL] Invalidation evidence is inconsistent.' }
    }
    else {
        # 逾時失效必須同時證明「就是本 target」與「確實超過固定上限」，缺一即不可信。
        if ($inv.observed_target_commit -ne $inv.ruled_target_commit) { throw '[UPGRADE_INVALIDATE_RESULT_FAIL] Invalidation evidence is inconsistent.' }
        foreach ($field in @('age_seconds','max_age_minutes')) { if ($null -eq $inv.PSObject.Properties[$field]) { throw "[UPGRADE_INVALIDATE_RESULT_FAIL] Invalidation evidence is missing: $field" } }
        if ([int]$inv.max_age_minutes -ne $FormalApplyMaximumAgeMinutes -or [double]$inv.age_seconds -le ($FormalApplyMaximumAgeMinutes * 60)) { throw '[UPGRADE_INVALIDATE_RESULT_FAIL] Expired invalidation evidence does not prove the transaction exceeded the fixed window.' }
    }
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
        $reasonCode = [string]$record.ReasonCode
        $journal.events = @($journal.events) + "invalidated:$reasonCode"
        $evidence = [ordered]@{ reason_code=$reasonCode; prior_state=[string]$journal.state; prior_result=[string]$journal.result; observed_target_commit=[string]$journal.target_commit; ruled_target_commit=$FormalUpgradeTargetCommit; invalidated_at_utc=[DateTime]::UtcNow.ToString('o'); invocation_mode='InvalidateFormalInternal'; journal_sha256_before=$beforeHash; manifest_sha256=$record.ManifestHashes }
        if ($reasonCode -eq 'expired_transaction') {
            # 已於判定前正規化，這裡直接沿用同一值；不得在此重複捨入。
            $evidence['age_seconds'] = [double]$record.AgeSeconds
            $evidence['max_age_minutes'] = $FormalApplyMaximumAgeMinutes
        }
        $journal | Add-Member -NotePropertyName invalidation -NotePropertyValue ([pscustomobject]$evidence) -Force
        $journal.state = 'invalidated'; $journal.result = 'invalidated'
        Save-MixedRepairJournal -JournalPath $record.Path -Journal $journal
        $after = [pscustomobject]@{ Path=$record.Path; Journal=(Get-Content -LiteralPath $record.Path -Raw -Encoding UTF8 | ConvertFrom-Json); ManifestHashes=$record.ManifestHashes }
        Assert-FormalInvalidatedJournal -Record $after -BeforeHash $beforeHash -ReasonCode $reasonCode
        return [pscustomobject]@{ schema=$FormalInvalidateSchema; mode='InvalidateFormalInternal'; result='invalidated'; transaction_id=$after.Journal.transaction_id; transaction_root=$Inputs.TransactionRoot; formal_target_write_count=0; invalidation=$after.Journal.invalidation }
    }
    finally { Close-FormalApplyExecutionLock -Lock $lock }
}
