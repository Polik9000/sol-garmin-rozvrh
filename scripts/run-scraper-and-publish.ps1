<#
    Spouští scraper lokálně (přes WSL, kde funguje běžná domácí IP - viz README,
    proč GitHub-hostovaný Actions runner nefunguje kvůli BotStopper) a publikuje
    výsledek do větve gh-pages. Určeno pro Windows Task Scheduler (wake timer).
#>
# Continue (ne Stop): nativní příkazy (git, wsl) níže občas píšou běžné hlášky na stderr,
# což PowerShell 5.1 při '2>&1' přemění na ErrorRecord - se Stop by to skript zbytečně přerušilo.
$ErrorActionPreference = "Continue"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LogFile = Join-Path $RepoRoot "scraper\run-log.txt"
$WslProject = "/home/tobia/sol-garmin-rozvrh/scraper"

function Log([string]$msg) {
    "$(Get-Date -Format o) $msg" | Out-File -Append -FilePath $LogFile -Encoding utf8
}

function ToWslPath([string]$windowsPath) {
    $full = (Resolve-Path -LiteralPath $windowsPath -ErrorAction SilentlyContinue)
    if (-not $full) { $full = $windowsPath }
    $drive = ([string]$full).Substring(0,1).ToLower()
    $rest = ([string]$full).Substring(2) -replace '\\','/'
    return "/mnt/$drive$rest"
}

Log "=== start ==="

Import-Module CredentialManager
$cred = Get-StoredCredential -Target "SOL-Scraper"
if (-not $cred) {
    Log "CHYBA: ulozene prihlasovaci udaje 'SOL-Scraper' nenalezeny v Credential Manageru."
    exit 1
}
# AES klíč (32 hex znaků) - rozvrh jde na veřejné GitHub Pages, bez klíče scraper skončí s kódem 64.
# Uložený jako heslo v Credential Manageru, target 'SOL-AES-Key' (uživatelské jméno libovolné).
$aesCred = Get-StoredCredential -Target "SOL-AES-Key"
if (-not $aesCred) {
    Log "CHYBA: AES klic 'SOL-AES-Key' nenalezen v Credential Manageru."
    exit 1
}

# WSLENV = proměnné se předají do WSL prostředí, ne přes argumenty procesu (heslo se tak
# neobjeví v seznamu procesů / historii příkazů).
$env:SOL_USER = $cred.UserName
$env:SOL_PASS = $cred.GetNetworkCredential().Password
# HEADED=1: BotStopper zřejmě detekuje headless Chromium samotný (ne jen datacenter IP) -
# viz README, ověřeno srovnáním headed/headless běhu ze stejné domácí sítě.
$env:HEADED = "1"
$env:SOL_AES_KEY = $aesCred.GetNetworkCredential().Password
$env:WSLENV = "SOL_USER:SOL_PASS:SOL_AES_KEY:HEADED"

try {
    # cmd /c slučuje stderr/stdout na úrovni OS - obchází PS 5.1 quirk, kdy '2>&1' na
    # nativním procesu s $ErrorActionPreference=Stop přeruší skript na první řádce stderr.
    $output = & cmd /c "chcp 65001 >NUL && wsl -d Ubuntu -u tobia --cd $WslProject -- dotnet run 2>&1"
    $exitCode = $LASTEXITCODE
    $output | Out-File -Append -FilePath $LogFile -Encoding utf8
}
finally {
    # Citlivé proměnné pryč z paměti procesu co nejdřív.
    Remove-Item Env:\SOL_USER, Env:\SOL_PASS, Env:\SOL_AES_KEY, Env:\HEADED, Env:\WSLENV -ErrorAction SilentlyContinue
}

if ($exitCode -ne 0) {
    Log "Scraper skoncil s kodem $exitCode, publikace se preskakuje."
    exit $exitCode
}

# Výsledek z WSL do Windows repa.
$jsonTmp = Join-Path $RepoRoot "rozvrh.new.json"
$jsonTmpWsl = "$(ToWslPath $RepoRoot)/rozvrh.new.json"
wsl -d Ubuntu -u tobia -- cp "$WslProject/out/rozvrh.json" $jsonTmpWsl 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8

if (-not (Test-Path $jsonTmp)) {
    Log "CHYBA: rozvrh.json se nepodarilo zkopirovat z WSL."
    exit 1
}

# Pojistka: na veřejné Pages smí jen šifrovaná obálka {"v":1,"iv":...,"c":...}, nikdy plaintext.
$payload = Get-Content -Raw -LiteralPath $jsonTmp
if ($payload -notmatch '^\{"v":1,"iv":"[A-Za-z0-9+/=]{24}","c":"[A-Za-z0-9+/=]+"\}$') {
    Log "CHYBA: rozvrh.json neni sifrovana obalka, publikace zrusena."
    Remove-Item $jsonTmp
    exit 1
}

Set-Location $RepoRoot
git fetch origin "gh-pages:refs/remotes/origin/gh-pages" 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8

# IV je deterministické (viz scraper/PayloadCrypto.cs) -> stejný rozvrh = bajtově stejný soubor.
$published = git show "origin/gh-pages:rozvrh.json" 2>$null
if ($LASTEXITCODE -eq 0 -and (($published -join "`n").Trim() -eq $payload.Trim())) {
    Remove-Item $jsonTmp
    Log "Rozvrh beze zmeny, publikace se preskakuje."
    Log "=== konec ==="
    exit 0
}

$worktreePath = Join-Path $RepoRoot "gh-pages-wt"
if (Test-Path $worktreePath) {
    git worktree remove $worktreePath --force 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8
    git worktree prune 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8
    # git worktree remove odmítne smazat cokoliv, co nerozpozná jako registrovanou worktree
    # (např. pozůstatek po dřívějším přerušeném běhu) - dorazit na úrovni souborového systému.
    if (Test-Path $worktreePath) {
        Remove-Item $worktreePath -Recurse -Force
    }
}
git branch -D gh-pages-publish 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8

# gh-pages je vždy JEDEN orphan commit + force push: repo je veřejné, takže historie větve
# by jinak navždy držela každou verzi rozvrhu (dřív i plaintextové). Historie rozvrhu nemá cenu.
git worktree add --orphan -b gh-pages-publish $worktreePath 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8

Copy-Item $jsonTmp (Join-Path $worktreePath "rozvrh.json") -Force
New-Item -ItemType File -Path (Join-Path $worktreePath ".nojekyll") -Force | Out-Null
Remove-Item $jsonTmp

Set-Location $worktreePath
git add rozvrh.json .nojekyll
git commit -q -m "rozvrh: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
git push --force origin HEAD:gh-pages 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8
if ($LASTEXITCODE -eq 0) { Log "Publikovano." } else { Log "CHYBA: push do gh-pages selhal." }

Set-Location $RepoRoot
git worktree remove $worktreePath --force 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8
if (Test-Path $worktreePath) { Remove-Item $worktreePath -Recurse -Force }
git branch -D gh-pages-publish 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8

Log "=== konec ==="
