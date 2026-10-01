# ŠOL → Garmin Fenix 5 Plus: rozvrh na hodinkách

Plně automatizovaný pipeline, který stáhne rozvrh ze Škola OnLine (ŠOL),
publikuje ho jako statický JSON na GitHub Pages a zobrazí na widgetu
Garmin Fenix 5 Plus. Tenhle soubor je určený jako startovní kontext pro
Claude Code (nebo pro tebe za pár týdnů) – shrnuje, co je hotové, proč je
to napsané zrovna takhle, a co ještě chybí dodělat.

## Stav projektu: dokončeno

Funkčně hotovo a nasazené, žádný další vývoj se neplánuje. Jediné známé
omezení je nespolehlivé probouzení notebooku ze spánku (viz „Windows
Modern Standby" níže) – akceptované, ne otevřený úkol. Drobné budoucí
zásahy (rotace AES klíče, oprava parseru při změně layoutu ŠOL) zvládne
tenhle README + kód bez dalšího plánování.

## Architektura (3 fáze)

```
scraper/            fáze 1 - C# + Playwright, přihlásí se do ŠOL,
                     scrapuje KZK001_KalendarTyden.aspx pro aktuální i
                     následující týden (klik na den v mini-kalendáři,
                     viz SolSession.FetchNextWeekHtmlAsync), spojí a
                     vyplivne out/rozvrh.json
scripts/            fáze 2 - lokální publikace (viz "Klíčová rozhodnutí" -
                     GitHub Actions NEFUNGUJE, ŠOL blokuje datacenter/headless).
                     scripts/run-scraper-and-publish.ps1 + Windows Task
                     Scheduler s wake timerem (Po-Pá 7:00-14:00) na
                     domácím PC, přes WSL Ubuntu. Wake timer je nespolehlivý
                     (viz "Windows Modern Standby" níže) - akceptované.
.github/workflows/  scrape.yml zůstává jen jako referenční/manuální build
                     check - jeho cron už NEBĚŽÍ (viz níže).
garmin-widget/       fáze 3 - Monkey C widget pro Fenix 5 Plus (tmavý
                     režim), stahuje JSON z GitHub Pages, ukazuje
                     aktuální + další hodinu s countdownem do konce/
                     začátku, mimo výuku "přestávka"/"konec školy"/
                     "víkend". START otevře scrollovatelný rozvrh na
                     oba stažené týdny.
```

Datový kontrakt mezi fázemi 1 a 3 (JSON pole objektů, bez mezer):
```json
[{"d":20260924,"n":"M","u":"PCH","s":"08:00","e":"08:45"}]
```
`d` = datum jako yyyyMMdd (int), `n` = zkratka předmětu, `u` = učebna,
`s`/`e` = začátek/konec "HH:MM". Řazeno podle (d, s) vzestupně. Jednopísmenné
klíče záměrně kvůli 64 KB paměťovému limitu widgetu ve fázi 3.

Tohle je jen **vnitřní/ladicí** tvar (`--parse` bez klíče, `--stdout`). Na
GitHub Pages jde výhradně šifrovaná obálka, viz „Zabezpečení“.

## Zabezpečení (rozvrh je osobní údaj, repo i Pages jsou veřejné)

**AES-128-CBC, dešifruje se přímo v hodinkách.** Obfuskace URL (`rozvrh_<hash>.json`)
tu nefunguje: větev `gh-pages` je ve veřejném repu, takže název souboru i celá
historie jsou vidět ve stromu repa na GitHubu.

```
ŠOL ──Playwright──► scraper (lokálně, WSL)
                     lessons ─► plaintext "SOL1,<n>\n20260930,M,PCH,0800,0845\n…"
                     AES-128-CBC(SOL_AES_KEY), IV = HMAC(odvozený klíč, plaintext)[..16]
                     ─► out/rozvrh.json = {"v":1,"iv":"<b64>","c":"<b64>"}
publish skript ──► kontrola regexem, že jde o obálku ─► gh-pages (1 orphan commit, force push)
hodinky ──makeWebRequest(JSON)──► Dictionary ─► base64 → ByteArray (StringUtil)
         ─► Cryptography.Cipher AES128/CBC (nativně) ─► kontrola "SOL1" ─► 5 paralelních polí
```

- Kryptografie běží nativně (`Toybox.Cryptography`, API 3.0.0, Fenix 5 Plus je
  CIQ 3.x), Monkey C dělá jen jeden lineární průchod bajty. Plaintext je řádkový
  formát, ne JSON: Monkey C neumí parsovat JSON z řetězce.
- Klíč nikdy není v repu: scraper ho čte z `SOL_AES_KEY` (lokálně z Windows Credential
  Manageru, target `SOL-AES-Key`; v Actions ze secretu `SOL_AES_KEY`). Hodinky ho
  čtou z nastavení aplikace (property `aesKey`).
- Bez klíče scraper v ostrém režimu skončí s kódem 64 a nic nezapíše. Publikace
  navíc odmítne cokoli, co neodpovídá tvaru obálky.
- Deterministické IV: stejný rozvrh dá bajtově stejný soubor, takže publikace commit
  přeskočí. Prozradí to jen „změnilo se / nezměnilo se“.
- MAC tu záměrně není: kdo by mohl podvrhnout obsah, musel by mít push do repa.
  Chráníme důvěrnost, ne autenticitu.
- Po přechodu na šifrování dostane `gh-pages` jediný orphan commit (force push).
  Staré plaintextové commity pak nejsou dosažitelné z žádné větve. GitHub je ale
  může ještě nějakou dobu vydat podle SHA a mohly je stáhnout forky či mirrory.
  Úplné odstranění = požádat GitHub Support o vymazání cache (odkaz na repo +
  informace, že šlo o osobní údaje).

**Klíč:** `openssl rand -hex 16` (nebo `python -c "import secrets;print(secrets.token_hex(16))"`),
32 hex znaků. Tentýž klíč patří na tři místa: Credential Manager / GitHub secret / hodinky.

## Co je hotové

- **Fáze 1** (`scraper/`): kompletní a ověřené proti živému ŠOL účtu
  (offline test: `dotnet run -- --parse fixtures/rozvrh.html --stdout`).
  Stahuje aktuální i následující týden a slučuje je (ověřeno živě: 55
  hodin ze dvou týdnů, ~2 KB payload).
- **Fáze 2** (`scripts/run-scraper-and-publish.ps1`): lokální publikace
  funguje end-to-end (přihlášení → parse → push do `gh-pages`). Přihlašovací
  údaje jsou ve Windows Credential Manageru (target `SOL-Scraper`), ne v
  souboru. `.github/workflows/scrape.yml` **NEPOUŽÍVÁME** pro ostrý provoz -
  viz "Klíčová rozhodnutí" proč. Windows Task Scheduler úloha
  `SOL-Rozvrh-Scraper` je zaregistrovaná (Po-Pá 7:00-14:00, každých 30 min,
  wake timer) a běží - samotný wake timer je ale nespolehlivý, viz
  "Windows Modern Standby" níže.
- **Fáze 3** (`garmin-widget/`): kompletní zdrojový kód widgetu, tmavý
  režim, countdown do konce/začátku hodiny, mimo výuku "přestávka" (s
  countdownem)/"konec školy"/"víkend" místo prostého "volno". Zkompilováno
  (`monkeyc -l 0`, `BUILD SUCCESSFUL`) a ověřeno proti živým datům.
- **Sentry monitoring** (`scraper/Program.cs`): DSN nastavený v Credential
  Manageru (`SOL-Sentry-DSN`), scraper posílá cron check-in i výjimky.

## Co chybí doplnit

- **`garmin-widget/manifest.xml`** – `id` je teď náhodně vygenerované GUID
  (funkční pro simulátor/lokální testy). Pro reálné publikování do Connect
  IQ Store by sis ho měl přegenerovat přes VS Code wizard ("Garmin: Create
  New Project" → nahradit vygenerovaný `manifest.xml`/`source/` obsahem
  z tohoto repa).

AES klíč (Credential Manager `SOL-AES-Key`, GitHub secret `SOL_AES_KEY`,
`garmin-widget/source/Secret.mc`), Sentry DSN (`SOL-Sentry-DSN`) i Windows
Task Scheduler úloha `SOL-Rozvrh-Scraper` jsou hotové a ověřené, viz
„Klíčová rozhodnutí" a „Zabezpečení" níže. Po jakékoli změně klíče ověř
v simulátoru `monkeydo … /t` (test `testDecryptVector`) a na hodinkách, že
widget neukazuje „Chybí krypto” ani „Špatný klíč”.

### Kompilace widgetu z příkazové řádky

`monkeyc` není v PATH a vyžaduje Javu, kterou tenhle stroj taky nemá v
PATH (je svázaná s Android Studiem). Developer key je v
`C:\Users\<user>\ConnectIQ-SDKManager\keys\developer_key.der`.

```
export PATH="/c/Program Files/Android/openjdk/jdk-21.0.8/bin:$PATH"
SDK=~/AppData/Roaming/Garmin/ConnectIQ/Sdks/<verze>/bin
"$SDK/monkeyc.bat" -f monkey.jungle -d fenix5plus -o out.prg \
  -y ~/ConnectIQ-SDKManager/keys/developer_key.der -l 0
```

Přísnější `-l` (type check level 1-3) hlásí pár chyb v předexistujícím
kódu (`Storage.getValue()` indexing, `method()` callback typy) - jde o
známé false-positivy Monkey C type checkeru, projekt se vždy stavěl na
`-l 0` a běží bez problémů.

## Klíčová rozhodnutí (aby ses/Claude Code nemusel ptát znovu)

- **Windows Modern Standby (S0ix) wake timer je nespolehlivý a NEŘEŠÍME to
  dál** – notebook (HP Victus 15, gaming řada) občas celé ráno prospí přes
  celé okno 7:00-14:00 bez jediného probuzení (ověřeno z `Kernel-Power`
  event logu: 14,5 h v kuse bez probuzení, `powercfg /lastwake` ukázal
  `Wake Source Count: 0` u probuzení, které bylo ve skutečnosti ruční).
  Vyšetřené a zavržené cesty, nezkoušet znovu:
  - Registry trik `PlatformAoAcOverride` (vynucení klasického S3 spánku) –
    `powercfg /a` potvrzuje, že firmware S1/S2/S3 vůbec nepodporuje, trik
    nemá co přepnout.
  - BIOS "Power On by RTC Alarm" – gaming notebooky HP (na rozdíl od
    EliteBook/ProBook) tuhle funkci typicky nemají; žádná HP utilita
    (OMEN Gaming Hub apod.) na stroji plánované zapínání nenabízí.
  - Přesun scraperu na druhý (Debian) počítač – blokují dva nezávislé
    problémy: chybí přihlášení (vyžaduje reinstall) a nejisté, jestli
    headed Chromium bez fyzického monitoru (Xvfb) neprojde stejně jako
    headless přes BotStopper (fáze 1 detekuje headless fingerprint, ne
    jen IP - viz "GitHub Actions cron" níže).
  - Zůstává: `StartWhenAvailable` na úloze dožene zmeškaný běh, jakmile se
    notebook probere (i ručně) - funguje jako záchranná síť, jen se
    zpožděním. Sentry cron monitor (viz níže) upozorní, když se nestihne.
- **Sentry monitoring** (`scraper/Program.cs`, balíček `Sentry`, DSN hotový
  viz „Co je hotové"): řeší největší slepé místo fáze 2 – celý pipeline běží na
  jednom domácím PC s wake timerem a bez monitoringu by tiché selhání (PC
  nevstalo, WSL spadlo, ŠOL změnil layout) zjistíš, až se podíváš na hodinky
  a uvidíš staré `sync`. Dvě věci najednou:
  - `SentrySdk.CaptureException` v catch větvích `Program.cs` – skutečné
    výjimky (login/parse/timeout) se stack trace.
  - Sentry Crons check-in (monitor slug `sol-scraper`, schedule
    `*/30 7-13 * * 1-5` Europe/Prague, `CheckInMargin` 5 min, `MaxRuntime`
    10 min) – "in_progress" na začátku ostrého běhu, "ok"/"error" na konci.
    Sentry sám pozná i **chybějící** check-in (úloha vůbec neproběhla) a
    pošle upozornění – to je ten hlavní přínos oproti pouhému logování chyb.
  - Gatováno na `!offline` (ne `--parse`/ladění) a na neprázdné `SENTRY_DSN` –
    bez DSN je `SentrySdk.Init` no-op a všechna volání níže taky (bezpečný
    "disabled hub"), scraper běží úplně stejně jako předtím.
  - Pokrývá jen fázi 1 (C# scraper), ne `git push` do `gh-pages` v
    `run-scraper-and-publish.ps1`/`scrape.yml` – ten skoro nikdy neselže a
    selhání by stejně zůstalo v `run-log.txt`.
- **GitHub Actions cron NEFUNGUJE a nikdy nebude** – ŠOL je chráněný
  anti-bot službou BotStopper (Techaro), která blokuje headless Chromium
  ještě před zobrazením přihlašovacího formuláře (ukáže "Jejda! Přístup
  zamítnut", `#JmenoUzivatele` pak logicky nikdy nenajdeš → scraper čeká
  na actionability až do 4min timeoutu). Ověřeno srovnáním: GH Actions
  (headless, cizí datacenter IP) = vždy blok; lokální headless ze stejné
  domácí sítě = **taky blok**; lokální `HEADED=1` ze stejné sítě = **OK**.
  Klíčový faktor je tedy headless režim samotný, ne (jen) IP. Proto fáze 2
  běží lokálně přes `scripts/run-scraper-and-publish.ps1` s `HEADED=1`
  (vyžaduje aktivní desktop session kvůli WSLg, ne nutně odemčenou
  obrazovku – stačí spánek/wake timer, ne úplné vypnutí/odhlášení).
  Obcházet BotStopper aktivně (spoofing, proxy) není řešení – je to
  bezpečnostní opatření školy, obcházení riskuje problém s účtem.
- **Scraper**: whitelist CSS tříd buněk (`DctInnerTableType10DataTD`,
  `KuvSuplujiciHodina`), suplované/odpadlé hodiny a školní akce se
  zahazují. Neznámá třída = WARN log + přeskočení, ne pád.
- **`git worktree add --orphan`** vyžaduje název větve přes `-b`, ne
  pozičně (`git worktree add --orphan -b gh-pages gh-pages-wt`, ne
  `... --orphan gh-pages gh-pages-wt`) – jinak "fatal: option '--orphan'
  and commit-ish cannot be used together". Tahle větev kódu se dlouho
  nikdy nespustila (scraper vždy padal dřív na BotStopperu), takže bug
  zůstal skrytý až do prvního živého lokálního běhu.
- **CI/CD**: exit kód 2 (zamítnuté heslo) jako jediný automaticky
  deaktivuje GitHub Actions workflow (riziko opakovaného špatného loginu
  a zámku účtu ŠOL). Ostatní kódy jen selžou a čekají na příští tik.
  (Poznámka: samotný cron trigger je teď irelevantní, viz výše - ale
  workflow zůstává funkční pro manuální build-check přes workflow_dispatch.)
- **Widget**: JSON se parsuje přes standardní `HTTP_RESPONSE_CONTENT_TYPE_JSON`
  (ne přes `TEXT_PLAIN` – ten má na této generaci API zdokumentované bugy),
  ale výsledný `Array<Dictionary>` se hned zhutní do 5 paralelních polí
  primitiv. Cache v `Application.Storage` s TTL 10 min, `deleteValue`
  před `setValue` (viz komentáře v `LessonStore.mc`).

## Pro Claude Code

Projekt je dokončený (viz „Stav projektu" výše) – nejde o backlog čekající
na dokončení, jen o referenci pro budoucí drobné zásahy. Než cokoliv
měnit, projdi hlavně „Klíčová rozhodnutí": pár cest (Modern Standby wake
timer, GitHub Actions cron) už bylo vyšetřeno a zavrženo, netřeba je
zkoušet znovu. Zdrojový kód je záměrně bez typovaných anotací
(`using ... as ...`, ne `import`/`as Type`) kvůli širší kompatibilitě
napříč verzemi Connect IQ SDK – pokud je nainstalovaná verze jistá,
klidně na modernější syntaxi přejdi.
