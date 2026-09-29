using System.Text.Json.Serialization;

namespace SolScraper;

/// Kontrakt mezi scraperem (fáze 1) a hodinkami (fáze 3). Jednopísmenné klíče: každý znak je bajt
/// přenosu a na hodinkách i paměť po naparsování do Dictionary.
public sealed record Lesson(
    [property: JsonPropertyName("d")] int Date,      // yyyyMMdd jako int, např. 20260924
    [property: JsonPropertyName("n")] string Name,   // zkratka předmětu
    [property: JsonPropertyName("u")] string Room,   // učebna; "" pokud chybí
    [property: JsonPropertyName("s")] string Start,  // "08:50"
    [property: JsonPropertyName("e")] string End);   // "09:35"; u bloků přes colspan konec posledního slotu

public static class ExitCodes
{
    public const int Ok = 0;
    public const int Transient = 1;            // síť, timeout, pád prohlížeče (po vyčerpání pokusů)
    public const int CredentialsRejected = 2;  // NIKDY automaticky neopakovat – riziko zámku účtu
    public const int ManualAction = 3;         // změna hesla apod.; vyžaduje člověka
    public const int ParseFailure = 4;         // změnila se struktura stránky
    public const int Config = 64;              // chybí proměnné prostředí
}

public abstract class ScrapeException(string message, int exitCode, Exception? inner = null)
    : Exception(message, inner)
{
    public int ExitCode { get; } = exitCode;
}

public sealed class TransientScrapeException(string message, Exception? inner = null)
    : ScrapeException(message, ExitCodes.Transient, inner);

public sealed class CredentialsRejectedException(string message)
    : ScrapeException(message, ExitCodes.CredentialsRejected);

public sealed class ManualActionRequiredException(string message)
    : ScrapeException(message, ExitCodes.ManualAction);

public sealed class ParseFailureException(string message)
    : ScrapeException(message, ExitCodes.ParseFailure);

public static class Log
{
    // stderr: stdout zůstává volný pro případný výstup JSONu (--stdout)
    public static void Info(string m) => Console.Error.WriteLine($"[{DateTime.UtcNow:HH:mm:ss}] {m}");
    public static void Warn(string m) => Console.Error.WriteLine($"[{DateTime.UtcNow:HH:mm:ss}] WARN {m}");
}
