# ŠOL → Garmin Fenix 5 Plus: rozvrh na hodinkách

Plně automatizovaný pipeline, který stáhne rozvrh ze Škola OnLine (ŠOL),
publikuje ho jako statický JSON na GitHub Pages a zobrazí na widgetu
Garmin Fenix 5 Plus. Tenhle soubor je určený jako startovní kontext pro
Claude Code (nebo pro tebe za pár týdnů) – shrnuje, co je hotové, proč je
to napsané zrovna takhle, a co ještě chybí dodělat.

## Architektura (3 fáze)

```
scraper/            fáze 1 - C# + Playwright, přihlásí se do ŠOL,
                     scrapuje KZK001_KalendarTyden.aspx, vyplivne
                     out/rozvrh.json
scripts/            fáze 2 - lokální publikace (viz "Klíčová rozhodnutí" -
                     GitHub Actions NEFUNGUJE, ŠOL blokuje datacenter/headless).
                     scripts/run-scraper-and-publish.ps1 + Windows Task
                     Scheduler s wake timerem (Po-Pá 7:00-14:00) na
                     domácím PC, přes WSL Ubuntu.
.github/workflows/  scrape.yml zůstává jen jako referenční/manuální build
                     check - jeho cron už NEBĚŽÍ (viz níže).
garmin-widget/       fáze 3 - Monkey C widget pro Fenix 5 Plus, stahuje
                     JSON z GitHub Pages, ukazuje aktuální + další hodinu
```

Datový kontrakt mezi fázemi 1 a 3 (JSON pole objektů, bez mezer):
```json
[{"d":20260924,"n":"M","u":"PCH","s":"08:00","e":"08:45"}]
```
`d` = datum jako yyyyMMdd (int), `n` = zkratka předmětu, `u` = učebna,
`s`/`e` = začátek/konec "HH:MM". Řazeno podle (d, s) vzestupně. Jednopísmenné
klíče záměrně kvůli 64 KB paměťovému limitu widgetu ve fázi 3.

## Co je hotové

- **Fáze 1** (`scraper/`): kompletní a ověřené proti živému ŠOL účtu
  (offline test: `dotnet run -- --parse fixtures/rozvrh.html --stdout`).
- **Fáze 2** (`scripts/run-scraper-and-publish.ps1`): lokální publikace
  funguje end-to-end (přihlášení → parse → push do `gh-pages`). Přihlašovací
  údaje jsou ve Windows Credential Manageru (target `SOL-Scraper`), ne v
  souboru. `.github/workflows/scrape.yml` **NEPOUŽÍVÁME** pro ostrý provoz -
  viz "Klíčová rozhodnutí" proč. Zbývá jen zaregistrovat Windows Task
  Scheduler úlohu s wake timerem (Po-Pá 7:00-14:00, každých 30 min),
  co spouští ten skript.
- **Fáze 3** (`garmin-widget/`): kompletní zdrojový kód widgetu,
  zkompilovaný a otestovaný v Connect IQ simulátoru.

## Co chybí doplnit

1. **Windows Task Scheduler úloha** na tomhle PC (Victus 15) - trigger
   Po-Pá 7:00-14:00 opakovaně každých 30 min, akce = spustit
   `scripts/run-scraper-and-publish.ps1`, zaškrtnuté "Wake the computer
   to run this task". Nejde nastavit vzdáleně, musí se udělat na místě
   v Task Scheduleru.
2. **`garmin-widget/manifest.xml`** – `id` je teď náhodně vygenerované GUID
   (funkční pro simulátor/lokální testy). Pro reálné publikování do Connect
   IQ Store by sis ho měl přegenerovat přes VS Code wizard ("Garmin: Create
   New Project" → nahradit vygenerovaný `manifest.xml`/`source/` obsahem
   z tohoto repa).

## Klíčová rozhodnutí (aby ses/Claude Code nemusel ptát znovu)

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

Otevři tuhle složku jako projekt (`claude` v terminálu, nebo VS Code s
Claude Code rozšířením) a klidně rovnou pokračuj bodem „Co chybí
doplnit" výše. Zdrojový kód je záměrně bez typovaných anotací
(`using ... as ...`, ne `import`/`as Type`) kvůli širší kompatibilitě
napříč verzemi Connect IQ SDK – pokud je nainstalovaná verze jistá,
klidně na modernější syntaxi přejdi.
