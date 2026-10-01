using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Playwright;
using Sentry;
using SolScraper;

// Volitelné: bez SENTRY_DSN SentrySdk.Init neběží a všechna CaptureException/CaptureCheckIn
// volání níže jsou no-op (Sentry SDK je v tomhle stavu bezpečný "disabled hub").
var sentryDsn = Env("SENTRY_DSN");
using var sentrySdk = sentryDsn != "" ? SentrySdk.Init(o => { o.Dsn = sentryDsn; }) : null;

// Cron monitoring jen pro ostré běhy (Po-Pá 7:00-13:30, viz Task Scheduler) - offline/--parse
// je ladění parseru, ne produkční scrape, a nemá smysl ho počítat do "úloha neběží".
var offlineForMonitor = Array.IndexOf(args, "--parse") is var parseArgIdx && parseArgIdx >= 0 && parseArgIdx + 1 < args.Length;
const string MonitorSlug = "sol-scraper";
SentryId? checkInId = null;
if (!offlineForMonitor && sentryDsn != "")
{
    checkInId = SentrySdk.CaptureCheckIn(MonitorSlug, CheckInStatus.InProgress, configureMonitorOptions: o =>
    {
        o.Interval("*/30 7-13 * * 1-5");
        o.TimeZone = "Europe/Prague";
        o.CheckInMargin = TimeSpan.FromMinutes(5);  // Task Scheduler má wake timer, může se opozdit
        o.MaxRuntime = TimeSpan.FromMinutes(10);     // shoduje se s ExecutionTimeLimit v Task Scheduleru
        o.FailureIssueThreshold = 1;
        o.RecoveryThreshold = 1;
    });
}

var exitCode = await RunAsync(args);

if (checkInId != null)
{
    SentrySdk.CaptureCheckIn(MonitorSlug, exitCode == ExitCodes.Ok ? CheckInStatus.Ok : CheckInStatus.Error, sentryId: checkInId);
}

return exitCode;

async Task<int> RunAsync(string[] args)
{

var jsonOptions = new JsonSerializerOptions
{
    WriteIndented = false,
    // Výchozí encoder escapuje ne-ASCII ("ě" -> \u011B, 6 B místo 2 B); JSON je určen pro paměťově omezený klient.
    Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
};

try
{
    var today = PragueToday();
    var outPath = Env("SOL_OUT", "out/rozvrh.json");
    var parseIdx = Array.IndexOf(args, "--parse");
    var offline = parseIdx >= 0 && parseIdx + 1 < args.Length;

    // Výstup jde na veřejné GitHub Pages -> v ostrém režimu bez klíče nic nezapisujeme.
    // Offline (--parse) bez klíče zapíše plaintext JSON pro ladění parseru.
    byte[]? aesKey = null;
    var keyHex = Env("SOL_AES_KEY");
    if (keyHex != "")
    {
        try { aesKey = PayloadCrypto.ParseKey(keyHex); }
        catch (ArgumentException ex) { Log.Warn(ex.Message); return ExitCodes.Config; }
    }
    else if (!offline) { Log.Warn("Chybí SOL_AES_KEY - plaintext rozvrh se nepublikuje."); return ExitCodes.Config; }

    string html;
    string? nextWeekHtml = null;
    if (offline)
    {
        html = await File.ReadAllTextAsync(args[parseIdx + 1]); // offline režim: bez prohlížeče a bez přihlášení
    }
    else
    {
        var user = Env("SOL_USER");
        var pass = Env("SOL_PASS");
        if (user == "" || pass == "") { Log.Warn("Chybí SOL_USER / SOL_PASS."); return ExitCodes.Config; }
        Log.Info("DIAG: start scrapingu (limit 4 min)...");
        // Tvrdý strop na celý běh. WaitAsync úlohu neruší, jen přestane čekat; proces skončí a driver zabije Chromium.
        (html, nextWeekHtml) = await ScrapeWithRetryAsync(user, pass).WaitAsync(TimeSpan.FromMinutes(4));
    }
    // Čas skutečného stažení ze ŠOL (ne čas, kdy si to později stáhnou hodinky z GitHub Pages).
    var scrapedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    List<Lesson> lessons;
    try
    {
        lessons = TimetableParser.Parse(html, today, Log.Warn);
        if (nextWeekHtml != null)
        {
            // Druhý týden parsujeme se stejným "today" - ResolveDate bere nejbližší rok k today,
            // což i týden dopředu funguje správně (výjimka jen přelom roku, viz TimetableParser).
            var nextLessons = TimetableParser.Parse(nextWeekHtml, today, Log.Warn);
            lessons = lessons.Concat(nextLessons).Distinct()
                .OrderBy(l => l.Date).ThenBy(l => l.Start, StringComparer.Ordinal).ToList();
        }
    }
    catch (ParseFailureException)
    {
        // Layout se změnil: ulož surové HTML, oprav parser offline přes --parse.
        var p = Path.Combine(Env("SOL_DEBUG_DIR", "debug"), "table-failed.html");
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(p))!);
        await File.WriteAllTextAsync(p, html);
        Log.Warn($"Surové HTML uloženo: {p}");
        throw;
    }

    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPath))!);
    var json = JsonSerializer.Serialize(lessons, jsonOptions);
    var payload = aesKey != null ? PayloadCrypto.Encrypt(PayloadCrypto.Serialize(lessons, scrapedAt), aesKey) : json;
    var tmp = outPath + ".tmp";
    await File.WriteAllTextAsync(tmp, payload);
    File.Move(tmp, outPath, overwrite: true); // temp + move: konzument nikdy neuvidí půl souboru

    Log.Info($"OK: {lessons.Count} hodin, {Encoding.UTF8.GetByteCount(payload)} B → {outPath}"
        + (aesKey != null ? " (AES-128-CBC)" : " (PLAINTEXT - jen pro ladění)"));
    if (args.Contains("--stdout")) Console.WriteLine(json);
    return ExitCodes.Ok;
}
catch (ScrapeException ex)
{
    Log.Warn($"{ex.GetType().Name}: {ex.Message}");
    SentrySdk.CaptureException(ex);
    return ex.ExitCode;
}
catch (System.TimeoutException ex)
{
    Log.Warn("Překročen celkový limit běhu (4 min).");
    SentrySdk.CaptureException(ex);
    return ExitCodes.Transient;
}
catch (Exception ex)
{
    Log.Warn("Neočekávaná chyba: " + ex);
    SentrySdk.CaptureException(ex);
    return ExitCodes.Transient;
}
}

static string Env(string key, string fallback = "") =>
    Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? v : fallback;

static DateTime PragueToday()
{
    TimeZoneInfo tz;
    try { tz = TimeZoneInfo.FindSystemTimeZoneById("Europe/Prague"); }                     // Linux, macOS, Windows s ICU
    catch (TimeZoneNotFoundException) { tz = TimeZoneInfo.FindSystemTimeZoneById("Central Europe Standard Time"); }
    return TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, tz).Date;
}

static async Task<(string ThisWeek, string? NextWeek)> ScrapeWithRetryAsync(string user, string pass)
{
    const int maxAttempts = 3;
    for (var attempt = 1; ; attempt++)
    {
        try
        {
            Log.Info($"DIAG: pokus {attempt}/{maxAttempts} – spouštím prohlížeč...");
            // Nový prohlížeč na každý pokus: po pádu/zaseknutí Chromia nesdílíme poškozený stav.
            await using var session = await SolSession.StartAsync(new(
                TimetableUrl: Env("SOL_TIMETABLE_URL", SolSession.DefaultTimetableUrl),
                DebugDir: Env("SOL_DEBUG_DIR", "debug"),
                AutoConsent: Env("SOL_AUTO_CONSENT", "1") != "0",
                Headless: Env("HEADED") != "1"));
            Log.Info($"DIAG: pokus {attempt} – prohlížeč běží, přihlašuji...");
            await session.LoginAsync(user, pass);
            Log.Info($"DIAG: pokus {attempt} – přihlášeno, stahuji rozvrh...");
            var thisWeek = await session.FetchTimetableHtmlAsync();
            string? nextWeek = null;
            try { nextWeek = await session.FetchNextWeekHtmlAsync(); }
            catch (Exception ex) { Log.Warn("Další týden se nepodařilo stáhnout, pokračuji jen s tímto: " + ex.Message); }
            return (thisWeek, nextWeek);
        }
        // Opakujeme jen přechodné chyby. CredentialsRejected / ManualAction / ParseFailure propadnou hned.
        catch (Exception ex) when (attempt < maxAttempts && ex is PlaywrightException or TransientScrapeException)
        {
            Log.Warn($"Pokus {attempt}/{maxAttempts} selhal: {ex.Message.Split('\n')[0]}");
            await Task.Delay(TimeSpan.FromSeconds(5 * attempt));
        }
    }
}
