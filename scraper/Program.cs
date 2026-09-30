using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Playwright;
using SolScraper;

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
        html = await ScrapeWithRetryAsync(user, pass).WaitAsync(TimeSpan.FromMinutes(4));
    }
    // Čas skutečného stažení ze ŠOL (ne čas, kdy si to později stáhnou hodinky z GitHub Pages).
    var scrapedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    List<Lesson> lessons;
    try { lessons = TimetableParser.Parse(html, today, Log.Warn); }
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
    return ex.ExitCode;
}
catch (System.TimeoutException)
{
    Log.Warn("Překročen celkový limit běhu (4 min).");
    return ExitCodes.Transient;
}
catch (Exception ex)
{
    Log.Warn("Neočekávaná chyba: " + ex);
    return ExitCodes.Transient;
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

static async Task<string> ScrapeWithRetryAsync(string user, string pass)
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
            return await session.FetchTimetableHtmlAsync();
        }
        // Opakujeme jen přechodné chyby. CredentialsRejected / ManualAction / ParseFailure propadnou hned.
        catch (Exception ex) when (attempt < maxAttempts && ex is PlaywrightException or TransientScrapeException)
        {
            Log.Warn($"Pokus {attempt}/{maxAttempts} selhal: {ex.Message.Split('\n')[0]}");
            await Task.Delay(TimeSpan.FromSeconds(5 * attempt));
        }
    }
}
