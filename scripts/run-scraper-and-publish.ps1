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

# WSLENV = proměnné se předají do WSL prostředí, ne přes argumenty procesu (heslo se tak
# neobjeví v seznamu procesů / historii příkazů).
$env:SOL_USER = $cred.UserName
$env:SOL_PASS = $cred.GetNetworkCredential().Password
# HEADED=1: BotStopper zřejmě detekuje headless Chromium samotný (ne jen datacenter IP) -
# viz README, ověřeno srovnáním headed/headless běhu ze stejné domácí sítě.
$env:HEADED = "1"
$env:WSLENV = "SOL_USER:SOL_PASS:HEADED"

try {
    # cmd /c slučuje stderr/stdout na úrovni OS - obchází PS 5.1 quirk, kdy '2>&1' na
    # nativním procesu s $ErrorActionPreference=Stop přeruší skript na první řádce stderr.
    $output = & cmd /c "chcp 65001 >NUL && wsl -d Ubuntu -u tobia --cd $WslProject -- dotnet run 2>&1"
    $exitCode = $LASTEXITCODE
    $output | Out-File -Append -FilePath $LogFile -Encoding utf8
}
finally {
    # Citlivé proměnné pryč z paměti procesu co nejdřív.
    Remove-Item Env:\SOL_USER, Env:\SOL_PASS, Env:\HEADED, Env:\WSLENV -ErrorAction SilentlyContinue
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

Set-Location $RepoRoot
git fetch origin "gh-pages:refs/remotes/origin/gh-pages" 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8
$fetchOk = ($LASTEXITCODE -eq 0)
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

if ($fetchOk) {
    git worktree add $worktreePath gh-pages 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8
} else {
    git worktree add --orphan -b gh-pages $worktreePath 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8
}

Copy-Item $jsonTmp (Join-Path $worktreePath "rozvrh.json") -Force
New-Item -ItemType File -Path (Join-Path $worktreePath ".nojekyll") -Force | Out-Null
Remove-Item $jsonTmp

Set-Location $worktreePath
git add rozvrh.json .nojekyll
git diff --cached --quiet
$hasDiff = ($LASTEXITCODE -ne 0)

if ($hasDiff) {
    git commit -q -m "rozvrh: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    git push origin gh-pages 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8
    Log "Publikovano."
} else {
    Log "Rozvrh beze zmeny, commit se preskakuje."
}

Set-Location $RepoRoot
git worktree remove $worktreePath --force 2>&1 | Out-File -Append -FilePath $LogFile -Encoding utf8
if (Test-Path $worktreePath) { Remove-Item $worktreePath -Recurse -Force }

Log "=== konec ==="
