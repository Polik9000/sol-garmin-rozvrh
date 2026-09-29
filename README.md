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
.github/workflows/  fáze 2 - GitHub Actions, cron Po-Pá 7:00-14:00
                     (Europe/Prague), commituje JSON do větve gh-pages
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

- **Fáze 1** (`scraper/`): kompletní, včetně offline testu parseru
  (`dotnet run -- --parse fixtures/rozvrh.html --stdout`).
- **Fáze 2** (`.github/workflows/scrape.yml`): kompletní workflow s
  DST-safe gate jobem, cache pro NuGet/Playwright, auto-deaktivací
  workflow po zamítnutém přihlášení (riziko zámku účtu ŠOL) a publikací
  do `gh-pages` přes `git worktree`.
- **Fáze 3** (`garmin-widget/`): kompletní zdrojový kód widgetu.

## Co chybí doplnit (vyžaduje účet/zařízení, nemůžu to vygenerovat sám)

1. **`garmin-widget/source/LessonStore.mc`** – nahradit `ROZVRH_URL`
   skutečným GitHub Pages endpointem z fáze 2
   (`https://<uživatel>.github.io/<repo>/rozvrh.json`).
2. **`garmin-widget/manifest.xml`** – `id="REPLACE-ME"` nahradit reálným
   GUID. Nejjednodušší cestou je založit projekt přes VS Code příkaz
   „Garmin: Create New Project" (zvol typ Widget, zařízení fenix5plus) a
   pak do vygenerované kostry nahradit `manifest.xml` a `source/` obsahem
   z tohoto repa – wizard zároveň vygeneruje `resources/strings/strings.xml`
   a launcher ikonu, které tu chybí.
3. **GitHub repo pro fázi 2**:
   - Secrets (Settings → Secrets and variables → Actions): `SOL_USER`, `SOL_PASS`.
   - GitHub Pages funguje na Free plánu jen u **veřejných** repozitářů –
     u privátního se karta Pages v Settings vůbec nezobrazí.
   - První běh ručně: Actions → „Scrape ŠOL rozvrh" → Run workflow →
     `force: true` (vytvoří větev `gh-pages`), pak Settings → Pages →
     Source: Deploy from a branch → `gh-pages` / `(root)`.
4. **`scraper/SolSession.cs`** – regexy `DismissName`/`ConsentName` pro
   cookie lištu a odsouhlasení podmínek jsou heuristika napsaná bez
   přístupu k reálné stránce po přihlášení. První ostrý běh dělej s
   `HEADED=1 dotnet run`, ať vidíš, jestli se něco neočekávaného neobjeví.

## Klíčová rozhodnutí (aby ses/Claude Code nemusel ptát znovu)

- **Scraper**: whitelist CSS tříd buněk (`DctInnerTableType10DataTD`,
  `KuvSuplujiciHodina`), suplované/odpadlé hodiny a školní akce se
  zahazují. Neznámá třída = WARN log + přeskočení, ne pád.
- **CI/CD**: exit kód 2 (zamítnuté heslo) jako jediný automaticky
  deaktivuje GitHub Actions workflow (riziko opakovaného špatného loginu
  a zámku účtu ŠOL). Ostatní kódy jen selžou a čekají na příští tik.
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
