$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$batPath = Join-Path $scriptDir "uninstall.bat"

if (-not (Test-Path $batPath)) {
    Write-Host "[錯誤] 找不到 uninstall.bat：" -ForegroundColor Red -NoNewline
    Write-Host " $batPath"
    Read-Host "按 Enter 結束"
    exit 1
}

Write-Host "==================================================="
Write-Host "     Laplace Sentry - 解除安裝精靈"
Write-Host "==================================================="
Write-Host ""
Write-Host "[警告] 此操作將移除："
Write-Host ""
Write-Host "  1. 桌面捷徑"
Write-Host "  2. Windows 前端安裝檔"
Write-Host "  3. WSL 後端執行副本"
Write-Host ""

$keepDataInput = Read-Host "是否先備份正式資料？(y/n)"
$keepData = if ($keepDataInput -match '^[Yy]$') { 'y' } else { 'n' }

$confirmInput = Read-Host "是否繼續解除安裝？([y] 繼續 / Enter 取消)"
$confirm = if ($confirmInput -match '^[Yy]$') { 'y' } else { 'n' }

if ($confirm -ne 'y') {
    Write-Host ""
    Write-Host "[資訊] 已取消解除安裝。"
    Read-Host "按 Enter 結束"
    exit 0
}

Write-Host ""
& $batPath $keepData $confirm
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "[錯誤] 卸載流程失敗，exit code = $exitCode" -ForegroundColor Red
    Read-Host "按 Enter 結束"
    exit $exitCode
}

exit 0