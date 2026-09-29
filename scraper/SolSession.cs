using System.Diagnostics;
using System.Text.RegularExpressions;
using Microsoft.Playwright;

namespace SolScraper;

public sealed record SessionOptions(string TimetableUrl, string DebugDir, bool AutoConsent, bool Headless);

public sealed class SolSession : IAsyncDisposable
{
    private const string LoginUrl = "https://aplikace.skolaonline.cz/SOL/Prihlaseni.aspx";
    // Odvozeno z relativního odkazu '../Rozvrh/KRO037…' v dodaném HTML. Neověřeno -> přepiš přes SOL_TIMETABLE_URL.
    public const string DefaultTimetableUrl = "https://aplikace.skolaonline.cz/SOL/App/Kalendar/KZK001_KalendarTyden.aspx";

    private const string Table = "#CCADynamicCalendarTable";
    private const string OverlayRoots =
        "[role=dialog], [aria-modal=true], .ui-dialog, .uk-modal.uk-open, .modal.show, [id*='cookie' i], [class*='cookie' i]";

    // Zavření / odložení / cookie lišta. Kotvené ^…$ = celý accessible name; odkaz, který slovo jen obsahuje, se nekliká.
    private static readonly Regex DismissName = new(
        @"^\s*(zavřít|zavřit|ok|rozumím|později|přeskočit|nyní ne|ne,? děkuji|přijmout(?: vše| všechny)?)\s*$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    // Odsouhlasení podmínek. Aktivní jen při SOL_AUTO_CONSENT != 0 a jen když se rozvrh nenačetl.
    private static readonly Regex ConsentName = new(
        @"^\s*(souhlasím|odsouhlasit|potvrdit|pokračovat|přijímám)\s*$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private readonly IPlaywright _pw;
    private readonly IBrowser _browser;
    private readonly IBrowserContext _ctx;
    private readonly IPage _page;
    private readonly SessionOptions _o;

    private SolSession(IPlaywright pw, IBrowser browser, IBrowserContext ctx, IPage page, SessionOptions o)
    {
        (_pw, _browser, _ctx, _page, _o) = (pw, browser, ctx, page, o);

        // (a) Nativní JS dialogy: bez posluchače je Playwright sám zavře (confirm = Cancel). S posluchačem je
        //     MUSÍME vyřídit, jinak stránka čeká na dialog a každá akce visí až do timeoutu.
        _page.Dialog += (s, d) => _ = HandleDialogAsync(d);

        // (b) Skutečná nová okna/záložky (window.open): zavřít, pracujeme jen s hlavní stránkou.
        _ctx.Page += (s, p) => { if (!ReferenceEquals(p, _page)) _ = SwallowAsync(p.CloseAsync()); };
    }

    public static async Task<SolSession> StartAsync(SessionOptions o)
    {
        var pw = await Playwright.CreateAsync();
        var browser = await pw.Chromium.LaunchAsync(new() { Headless = o.Headless });
        var ctx = await browser.NewContextAsync(new()
        {
            // cs-CZ: UI ŠOL i regexy níže jsou česky; výchozí en-US mění Accept-Language a potenciálně texty.
            Locale = "cs-CZ",
            // Runner běží v UTC. Pokud stránka počítá "dnešní týden" z JS Date, bez tohoto by se kolem půlnoci rozcházela.
            TimezoneId = "Europe/Prague",
            ViewportSize = new() { Width = 1366, Height = 900 },
        });
        ctx.SetDefaultTimeout(20_000);
        ctx.SetDefaultNavigationTimeout(30_000);
        return new SolSession(pw, browser, ctx, await ctx.NewPageAsync(), o);
    }

    public async Task LoginAsync(string user, string pass)
    {
        await GoToAsync(LoginUrl);
        Log.Info("DIAG: login stránka načtena, řeším překryvy...");
        var dismissedSw = Stopwatch.StartNew();
        var dismissed = await DismissOverlaysAsync(); // cookie lišta může překrývat tlačítko; klik by pak čekal na actionability do timeoutu
        Log.Info($"DIAG: DismissOverlaysAsync za {dismissedSw.ElapsedMilliseconds} ms, zavřel něco={dismissed}");
        // DOČASNÉ: ukázat přesný stav stránky před vyplněním formuláře (odstranit po odladění CI vs. lokál).
        await DumpAsync("login-page-state");

        var fillSw = Stopwatch.StartNew();
        await _page.Locator("#JmenoUzivatele").FillAsync(user);
        Log.Info($"DIAG: jméno vyplněno za {fillSw.ElapsedMilliseconds} ms");
        fillSw.Restart();
        await _page.Locator("#HesloUzivatele").FillAsync(pass);
        Log.Info($"DIAG: heslo vyplněno za {fillSw.ElapsedMilliseconds} ms");

        // Baseline: .tm-error je skrytá přes custom.css neznámým způsobem. Pokud ji Playwright vidí jako viditelnou
        // už před odesláním, nelze na ni spoléhat a rozhoduje jen URL + timeout.
        var errBefore = await IsVisibleSafeAsync(".tm-error");
        await _page.Locator("#btnLogin").ClickAsync();
        Log.Info("DIAG: formulář odeslán, čekám na přesměrování (max 30 s)...");

        // Polling místo RunAndWaitForNavigationAsync (deprecated, racy). Neúspěšný login je POST na tutéž URL,
        // takže WaitForURL by neúspěch nepoznal – rozlišujeme "URL opustila Prihlaseni.aspx" vs. "chybová hláška".
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (DateTime.UtcNow < deadline)
        {
            if (!IsLoginUrl(_page.Url))
            {
                Log.Info("Přihlášeno → " + PathOnly(_page.Url));
                return;
            }
            if (!errBefore && await IsVisibleSafeAsync(".tm-error"))
                throw new CredentialsRejectedException("ŠOL zobrazil chybu přihlášení (hesla/zámek účtu).");
            await Task.Delay(250);
        }
        throw new CredentialsRejectedException("Po odeslání formuláře zůstala stránka na přihlášení (30 s).");
    }

    public async Task<string> FetchTimetableHtmlAsync()
    {
        for (var attempt = 1; attempt <= 3; attempt++)
        {
            Log.Info($"DIAG: rozvrh pokus {attempt}/3 – navigace na {PathOnly(_o.TimetableUrl)}...");
            await GoToAsync(_o.TimetableUrl);
            if (await WaitForTableAsync(attempt == 1 ? 20 : 10)) return await ReadStableTableHtmlAsync();

            Log.Warn($"Tabulka rozvrhu nenalezena (pokus {attempt}), url={PathOnly(_page.Url)}");
            if (IsLoginUrl(_page.Url)) throw new TransientScrapeException("Session vypršela – přesměrování na přihlášení.");
            if (await ResolveInterruptionsAsync()) await SettleAsync();
        }
        await DumpAsync("timetable-missing");
        throw new TransientScrapeException($"Rozvrh se nenačetl ani po 3 pokusech, url={PathOnly(_page.Url)}");
    }

    // ---------- čekání na DOM ----------

    private async Task<bool> WaitForTableAsync(int seconds)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            // Čekáme na řádek dne, ne jen na <table>: kostra tabulky může existovat dřív než data (asynchronní plnění).
            await _page.Locator($"{Table} tr.RowOdd, {Table} tr.RowEven").First
                .WaitForAsync(new() { State = WaitForSelectorState.Attached, Timeout = seconds * 1000 });
            Log.Info($"DIAG: WaitForTableAsync nalezeno za {sw.ElapsedMilliseconds} ms");
            return true;
        }
        catch (PlaywrightException) // TimeoutException je potomek PlaywrightException
        {
            Log.Info($"DIAG: WaitForTableAsync timeout po {sw.ElapsedMilliseconds} ms (limit {seconds * 1000} ms)");
            return false;
        }
    }

    private async Task<string> ReadStableTableHtmlAsync()
    {
        var sw = Stopwatch.StartNew();
        // Dvě po sobě shodná čtení = DOM se přestal měnit. Levnější a spolehlivější než NetworkIdle.
        var table = _page.Locator(Table);
        string? prev = null;
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (DateTime.UtcNow < deadline)
        {
            var html = await table.EvaluateAsync<string>("e => e.outerHTML");
            if (html == prev)
            {
                Log.Info($"DIAG: ReadStableTableHtmlAsync stabilní za {sw.ElapsedMilliseconds} ms");
                return html;
            }
            prev = html;
            await Task.Delay(500);
        }
        Log.Info($"DIAG: ReadStableTableHtmlAsync nestabilní i po {sw.ElapsedMilliseconds} ms, vracím poslední stav");
        return prev!; // nestabilní: vracíme poslední stav, případnou nekonzistenci odhalí parser
    }

    // ---------- mezikroky a pop-upy ----------

    /// Vrací true, pokud něco vyřídil (stránka se mohla změnit). Vyhazuje ManualActionRequired u změny hesla.
    private async Task<bool> ResolveInterruptionsAsync()
    {
        // Změna hesla: ≥2 viditelná pole hesla (nové + potvrzení). Na přihlašovací stránce je pole jedno.
        if (await CountVisibleAsync("input[type=password]") >= 2)
        {
            if (await TryClickAsync(_page.Locator("body"), DismissName, "změna hesla → později")) return true;
            await DumpAsync("password-change");
            throw new ManualActionRequiredException(
                "ŠOL vyžaduje změnu hesla. Změň ho ručně a aktualizuj SOL_PASS; scraper heslo sám nemění.");
        }
        return await DismissOverlaysAsync() || await AcceptConsentAsync();
    }

    private async Task<bool> DismissOverlaysAsync()
    {
        try
        {
            var roots = _page.Locator(OverlayRoots);
            var n = Math.Min(await roots.CountAsync(), 5);
            for (var i = 0; i < n; i++)
            {
                var root = roots.Nth(i);
                if (await root.IsVisibleAsync() && await TryClickAsync(root, DismissName, "překryv → zavřít")) return true;
            }
        }
        catch (PlaywrightException) { /* DOM se mezitím změnil; další průchod to zkusí znovu */ }
        return false;
    }

    private async Task<bool> AcceptConsentAsync()
    {
        if (!_o.AutoConsent) return false;
        try
        {
            // Některé souhlasy aktivují tlačítko až po zaškrtnutí políčka. Vždy .First: po zaškrtnutí se seznam
            // ":not(:checked)" zkracuje, takže index i by přeskakoval.
            for (var i = 0; i < 3; i++)
            {
                var box = _page.Locator("input[type=checkbox]:not(:checked)").First;
                if (!await box.IsVisibleAsync()) break;
                await box.CheckAsync(new() { Timeout = 3_000 });
            }
        }
        catch (PlaywrightException) { }
        return await TryClickAsync(_page.Locator("body"), ConsentName, "souhlas / pokračovat");
    }

    // Tlačítko hledáme přes accessible name (role button/link), ne přes CSS třídu: přežije redesign markupu.
    // <input type=submit value="OK"> má role=button a name z atributu value.
    private async Task<bool> TryClickAsync(ILocator scope, Regex name, string what)
    {
        foreach (var role in new[] { AriaRole.Button, AriaRole.Link })
        {
            var target = scope.GetByRole(role, new() { NameRegex = name }).First;
            try
            {
                if (!await target.IsVisibleAsync()) continue;
                Log.Info($"Mezikrok: {what}");
                await target.ClickAsync(new() { Timeout = 5_000 });
                return true;
            }
            catch (PlaywrightException) { /* zmizelo / překryto – zkusíme další roli */ }
        }
        return false;
    }

    // ---------- pomocné ----------

    private async Task GoToAsync(string url)
    {
        var sw = Stopwatch.StartNew();
        var resp = await _page.GotoAsync(url, new() { WaitUntil = WaitUntilState.DOMContentLoaded });
        Log.Info($"DIAG: GoToAsync({PathOnly(url)}) za {sw.ElapsedMilliseconds} ms, HTTP {resp?.Status.ToString() ?? "?"}");
        if (resp is { Ok: false }) throw new TransientScrapeException($"HTTP {resp.Status} pro {PathOnly(url)}");
    }

    private async Task SettleAsync()
    {
        try { await _page.WaitForLoadStateAsync(LoadState.DOMContentLoaded, new() { Timeout = 10_000 }); }
        catch (PlaywrightException) { }
        await Task.Delay(300);
    }

    private async Task<bool> IsVisibleSafeAsync(string selector)
    {
        try { return await _page.Locator(selector).First.IsVisibleAsync(); }
        catch (PlaywrightException) { return false; } // "Execution context was destroyed" při probíhající navigaci
    }

    private async Task<int> CountVisibleAsync(string selector, int max = 6)
    {
        var loc = _page.Locator(selector);
        var n = Math.Min(await loc.CountAsync(), max);
        var visible = 0;
        for (var i = 0; i < n; i++) if (await loc.Nth(i).IsVisibleAsync()) visible++;
        return visible;
    }

    public async Task DumpAsync(string tag)
    {
        try
        {
            Directory.CreateDirectory(_o.DebugDir);
            var stem = Path.Combine(_o.DebugDir, $"{DateTime.UtcNow:yyyyMMdd-HHmmss}-{tag}");
            await File.WriteAllTextAsync(stem + ".html", await _page.ContentAsync());
            await _page.ScreenshotAsync(new() { Path = stem + ".png", FullPage = true });
            Log.Warn($"Debug dump: {stem}.(html|png)");
        }
        catch (Exception ex) { Log.Warn("Dump selhal: " + ex.Message); }
    }

    private static bool IsLoginUrl(string url) => url.Contains("Prihlaseni.aspx", StringComparison.OrdinalIgnoreCase);

    // Do logů jen cesta bez query stringu (mohl by nést tokeny).
    private static string PathOnly(string url)
    {
        try { return new Uri(url).GetLeftPart(UriPartial.Path); } catch { return "?"; }
    }

    private static async Task HandleDialogAsync(IDialog d)
    {
        var msg = d.Message.Length <= 100 ? d.Message : d.Message[..100] + "…";
        Log.Info($"JS dialog [{d.Type}]: {msg}");
        try { await d.AcceptAsync(); } catch (PlaywrightException) { }
    }

    private static async Task SwallowAsync(Task t)
    {
        try { await t; } catch (PlaywrightException) { }
    }

    public async ValueTask DisposeAsync()
    {
        try { await _ctx.CloseAsync(); await _browser.CloseAsync(); } catch { }
        _pw.Dispose();
    }
}
