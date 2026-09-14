# Minidoracat PZ MOD 家族 — 測試啟動器（統一版，正本：D:/github/pz-family-docs/scripts/）
# 零設定：MOD 名稱自動偵測；遊戲路徑可用環境變數 PZ_PATH 覆寫；伺服器名可在選單切換。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================
# 設定（一般不需改；改用環境變數 PZ_PATH）
# ============================================
$PZ_PATH = if ($env:PZ_PATH) { $env:PZ_PATH } else { "D:\SteamLibrary\steamapps\common\ProjectZomboid" }
# .bat 以 & ScriptBlock 執行；初始化與選單寫入須同 scope，否則區域預設值會遮住選擇。
$script:SERVER_NAME = "servertest"
$SERVER_MEMORY = "3072m"
$ZomboidDir = Join-Path $env:USERPROFILE "Zomboid"
$ServerIniDir = Join-Path $ZomboidDir "Server"

# 專案根與 MOD 名（只用於視窗標題）
if ($env:PROJECT_ROOT) { $ProjectRoot = $env:PROJECT_ROOT.TrimEnd('\') }
elseif ($PSScriptRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
else { $ProjectRoot = (Get-Location).Path }
$modInfo = @(Get-ChildItem (Join-Path $ProjectRoot "MOD") -Recurse -Filter "mod.info" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\Contents\\mods\\[^\\]+\\42\\mod\.info$' } | Select-Object -First 1)
$MOD_LABEL = if ($modInfo) {
    $n = (Get-Content $modInfo[0].FullName -Encoding UTF8 | Where-Object { $_ -match '^\s*name=' } | Select-Object -First 1) -replace '^\s*name=', ''
    $id = (Get-Content $modInfo[0].FullName -Encoding UTF8 | Where-Object { $_ -match '^\s*id=' } | Select-Object -First 1) -replace '^\s*id=', ''
    "$id  $n"
} else { Split-Path -Leaf $ProjectRoot }

if (-not (Test-Path (Join-Path $PZ_PATH "ProjectZomboid64.exe"))) {
    Write-Host ""
    Write-Host "[錯誤] 找不到 Project Zomboid: $PZ_PATH" -ForegroundColor Red
    Write-Host "設定環境變數 PZ_PATH 指向遊戲安裝目錄，或修改腳本頂部預設值。" -ForegroundColor Yellow
    Read-Host "按 Enter 結束"
    exit 1
}

# ============================================
# 功能函式
# ============================================

function Start-PZClient {
    param([switch]$Debug, [switch]$NoSteam)
    $argList = @()
    if ($NoSteam) { $argList += "-nosteam" }
    if ($Debug) { $argList += "-debug" }
    $mode = if ($Debug) { "Debug 模式" } else { "一般模式" }
    $network = if ($NoSteam) { "no-Steam" } else { "Steam" }
    Write-Host "[客戶端] 啟動客戶端 ($network / $mode)..." -ForegroundColor Cyan
    $start = @{ FilePath = (Join-Path $PZ_PATH "ProjectZomboid64.exe"); WorkingDirectory = $PZ_PATH }
    if ($argList.Count -gt 0) { $start.ArgumentList = $argList }
    Start-Process @start
    Write-Host "[客戶端] 已啟動。" -ForegroundColor Green
}

function Get-PZServerProcesses {
    param([string]$Name)
    $pattern = '-servername\s+"?' + [regex]::Escape($Name) + '"?(\s|$)'
    @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'zombie\.network\.GameServer' -and $_.CommandLine -match $pattern })
}

function Start-PZServer {
    param([switch]$NoSteam)
    $network = if ($NoSteam) { "no-Steam" } else { "Steam" }
    $running = @(Get-PZServerProcesses -Name $script:SERVER_NAME)
    foreach ($process in $running) {
        $steam = $process.CommandLine -match '(?:^|\s)-Dzomboid\.steam=1(?:\s|$)' -and $process.CommandLine -notmatch '(?:^|\s)-nosteam(?:\s|$)'
        if ($steam -eq [bool]$NoSteam) {
            Write-Host "[伺服器] $script:SERVER_NAME 已在另一連線模式執行。請先於原伺服器輸入 quit 正常關服，再切換為 $network；本次不啟動。" -ForegroundColor Red
            return $false
        }
    }
    if ($running.Count -gt 0) {
        Write-Host "[伺服器] $script:SERVER_NAME ($network) 已在執行，沿用原程序。" -ForegroundColor Yellow
        return $true
    }
    Write-Host "[伺服器] 啟動專用伺服器 $script:SERVER_NAME（$network，記憶體 $SERVER_MEMORY）..." -ForegroundColor Cyan
    $steamFlag = if ($NoSteam) { "-Dzomboid.steam=0" } else { "-Dzomboid.steam=1" }
    $javaPath = Join-Path $PZ_PATH "jre64\bin\java.exe"
    $javaArgs = @(
        "-XX:+UseZGC", "-XX:-CreateCoredumpOnCrash", "-XX:-OmitStackTraceInFastThrow",
        "-Xmx$SERVER_MEMORY",
        $steamFlag,
        "-Djava.library.path=natives/;natives/win64/;./",
        "-cp", ".;projectzomboid.jar",
        "zombie.network.GameServer", "-servername", $script:SERVER_NAME
    )
    Start-Process -FilePath $javaPath -ArgumentList $javaArgs -WorkingDirectory $PZ_PATH
    Write-Host "[伺服器] 已在新視窗啟動；可在該視窗輸入指令（例：grantadmin <玩家名>）。" -ForegroundColor Green
    return $true
}

function Start-ServerAndClients {
    param([int]$Clients, [switch]$Debug, [switch]$NoSteam)
    $iniPath = Join-Path $ServerIniDir ($script:SERVER_NAME + ".ini")
    $serverPort = "16261"
    if (Test-Path -LiteralPath $iniPath) {
        $portLine = Get-Content -LiteralPath $iniPath -Encoding UTF8 -ErrorAction Stop |
            Where-Object { $_ -match '^\s*DefaultPort\s*=' } | Select-Object -First 1
        if ($portLine) { $serverPort = ($portLine -split '=', 2)[1].Trim() }
    }
    $savePath = Join-Path (Join-Path $ZomboidDir "Saves/Multiplayer") $script:SERVER_NAME
    if (-not (Start-PZServer -NoSteam:$NoSteam)) { return }
    $mode = if ($Debug) { "Debug" } else { "一般" }
    for ($i = 1; $i -le $Clients; $i++) {
        if ($i -gt 1) { Start-Sleep -Seconds 3 }
        Write-Host "[自動] 啟動第 $i 個客戶端 ($mode)..." -ForegroundColor Cyan
        Start-PZClient -Debug:$Debug -NoSteam:$NoSteam
    }
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  伺服器: $script:SERVER_NAME   連線位址: 127.0.0.1:$serverPort   客戶端: $Clients ($mode)" -ForegroundColor Green
    Write-Host "  設定檔: $iniPath" -ForegroundColor Green
    Write-Host "  伺服器存檔: $savePath" -ForegroundColor Green
    Write-Host "  請在遊戲選「加入」並使用上述位址與埠；本選項不會自動連線，勿沿用舊伺服器連線。" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Green
}

function Select-ServerName {
    $inis = @(Get-ChildItem $ServerIniDir -Filter "*.ini" -File -ErrorAction SilentlyContinue)
    if ($inis.Count -eq 0) { Write-Host "[伺服器] $ServerIniDir 下沒有 ini（先跑一次伺服器會自動產生）" -ForegroundColor Yellow; return }
    for ($i = 0; $i -lt $inis.Count; $i++) {
        $mark = if ($inis[$i].BaseName -eq $script:SERVER_NAME) { "  <- 目前" } else { "" }
        Write-Host "  [$($i + 1)] $($inis[$i].BaseName)$mark"
    }
    $sel = Read-Host "選擇伺服器設定（Enter 取消）"
    $n = 0
    if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $inis.Count) {
        $script:SERVER_NAME = $inis[$n - 1].BaseName
        Write-Host "[伺服器] 已切換為 $script:SERVER_NAME" -ForegroundColor Green
    }
}

function Stop-AllPZ {
    Write-Host "[停止] 正在停止 PZ 相關進程..." -ForegroundColor Yellow
    $stopped = 0
    Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'zomboid|ProjectZomboid' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $stopped++ }
    Get-Process -Name "ProjectZomboid64" -ErrorAction SilentlyContinue | ForEach-Object { $_ | Stop-Process -Force; $stopped++ }
    if ($stopped -gt 0) { Write-Host "[停止] 已停止 $stopped 個進程。" -ForegroundColor Green }
    else { Write-Host "[停止] 沒有執行中的 PZ 進程。" -ForegroundColor DarkGray }
}

function Open-Logs {
    foreach ($f in @("console.txt", "server-console.txt")) {
        $p = Join-Path $ZomboidDir $f
        if (Test-Path $p) { Write-Host "  $p  ($([math]::Round((Get-Item $p).Length / 1KB)) KB)" } else { Write-Host "  $p  (不存在)" -ForegroundColor DarkGray }
    }
    Start-Process explorer.exe $ZomboidDir
}

# ============================================
# 主選單
# ============================================
$Host.UI.RawUI.WindowTitle = "PZ Test Launcher - $MOD_LABEL"

while ($true) {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Project Zomboid MOD 測試啟動器" -ForegroundColor Cyan
    Write-Host "  $MOD_LABEL" -ForegroundColor Cyan
    Write-Host "  伺服器設定: $script:SERVER_NAME    PZ: $PZ_PATH" -ForegroundColor DarkGray
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Steam 模式（優先使用；請先登入 Steam）" -ForegroundColor Green
    Write-Host "  [1] 一般客戶端（無 Debug）"
    Write-Host "  [2] Debug 客戶端"
    Write-Host "  [3] 專用伺服器"
    Write-Host "  [4] 一鍵：伺服器 + 一般客戶端"
    Write-Host "  [5] 一鍵：伺服器 + Debug 客戶端"
    Write-Host ""
    Write-Host "  no-Steam 模式（本機多開；不提供 SteamID）" -ForegroundColor Yellow
    Write-Host "  [N1] 一般客戶端（無 Debug）    [N2] Debug 客戶端"
    Write-Host "  [N3] 專用伺服器"
    Write-Host "  [N4] 一鍵：伺服器 + 一般客戶端"
    Write-Host "  [N5] 一鍵：伺服器 + Debug 客戶端"
    Write-Host "  [N6] 一鍵：伺服器 + 2 個一般客戶端"
    Write-Host "  [N7] 一鍵：伺服器 + 2 個 Debug 客戶端"
    Write-Host "  [N8] 兩個 Debug 客戶端（Host：第一個 HOST、第二個 JOIN）"
    Write-Host "  伺服器與客戶端須使用相同模式；切換前請先正常關服。" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [S] 切換伺服器設定檔（Server\*.ini）"
    Write-Host "  [L] 開啟 Zomboid 目錄與 log 大小"
    Write-Host "  [0] 停止所有 PZ 進程"
    Write-Host "  [Q] 離開"
    Write-Host ""
    $choice = Read-Host "請選擇"

    switch ($choice.ToUpper()) {
        "1" { Start-PZClient; Read-Host "按 Enter 繼續" }
        "2" { Start-PZClient -Debug; Read-Host "按 Enter 繼續" }
        "3" { [void](Start-PZServer); Read-Host "按 Enter 繼續" }
        "4" { Start-ServerAndClients -Clients 1; Read-Host "按 Enter 繼續" }
        "5" { Start-ServerAndClients -Clients 1 -Debug; Read-Host "按 Enter 繼續" }
        "N1" { Start-PZClient -NoSteam; Read-Host "按 Enter 繼續" }
        "N2" { Start-PZClient -NoSteam -Debug; Read-Host "按 Enter 繼續" }
        "N3" { [void](Start-PZServer -NoSteam); Read-Host "按 Enter 繼續" }
        "N4" { Start-ServerAndClients -Clients 1 -NoSteam; Read-Host "按 Enter 繼續" }
        "N5" { Start-ServerAndClients -Clients 1 -NoSteam -Debug; Read-Host "按 Enter 繼續" }
        "N6" { Start-ServerAndClients -Clients 2 -NoSteam; Read-Host "按 Enter 繼續" }
        "N7" { Start-ServerAndClients -Clients 2 -NoSteam -Debug; Read-Host "按 Enter 繼續" }
        "N8" {
            Start-PZClient -NoSteam -Debug
            Write-Host "[Host模式] 等待 5 秒後開第二個客戶端..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 5
            Start-PZClient -NoSteam -Debug
            Read-Host "按 Enter 繼續"
        }
        "S" { Select-ServerName; Read-Host "按 Enter 繼續" }
        "L" { Open-Logs; Read-Host "按 Enter 繼續" }
        "0" { Stop-AllPZ; Read-Host "按 Enter 繼續" }
        "Q" { exit 0 }
    }
}
