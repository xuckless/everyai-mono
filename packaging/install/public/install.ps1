# EveryAI installer for Windows: installs (or updates) EveryAI from the Microsoft Store through winget.
#
#   irm https://get.everyai.dev/install.ps1 | iex
#
# The Store signs the app and keeps it up to date. Without winget, the Store page opens instead.
# Your settings, chats and sessions are never touched.

$ErrorActionPreference = 'Stop'
$StoreId = '9PHCKCV3J9S9'
$StorePage = "ms-windows-store://pdp/?productid=$StoreId"

function Say($text) { Write-Host "==> $text" -ForegroundColor Cyan }

function Open-Store {
    Say 'Opening EveryAI in the Microsoft Store; click Get (or Install) there.'
    Start-Process $StorePage
}

$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Host 'winget (App Installer) is not available on this PC.'
    Open-Store
    return
}

Say 'Installing EveryAI from the Microsoft Store with winget'
& winget install --id $StoreId --source msstore --exact --accept-package-agreements --accept-source-agreements --silent
$code = $LASTEXITCODE

# 0x8A15002B: already installed and no newer version.
if ($code -eq 0) {
    Say 'Done. Open EveryAI from the Start menu. The Store keeps it up to date.'
} elseif ($code -eq -1978335189) {
    Say 'EveryAI is already installed and up to date.'
} else {
    Write-Host ("winget stopped with code 0x{0:X8}." -f $code) -ForegroundColor Yellow
    Open-Store
}
