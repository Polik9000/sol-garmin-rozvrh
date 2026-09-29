using System.Text.RegularExpressions;
using AngleSharp.Dom;
using AngleSharp.Html.Parser;

namespace SolScraper;

/// Čistá funkce HTML -> Lesson[]. Žádné I/O ani Playwright: testovatelné offline nad uloženým HTML.
public static class TimetableParser
{
    // CSS třídy vnitřních buněk (odvozeno z dodaného HTML)
    private const string CssRegular = "DctInnerTableType10DataTD"; // běžná hodina           -> ANO
    private const string CssSubstituting = "KuvSuplujiciHodina";   // suplující (skutečně proběhne) -> ANO
    private const string CssSubstituted = "KuvSuplovanaHodina";    // původní, odpadla/přesunuta   -> NE
    private const string CssSchoolEvent = "KuvSkolniAkceHodina";   // školní akce, není hodina     -> NE

    private static readonly Regex TimeRange = new(@"(\d{1,2}):(\d{2})\s*[-–]\s*(\d{1,2}):(\d{2})");
    private static readonly Regex DayMonth = new(@"(\d{1,2})\.\s*(\d{1,2})\.");

    public static List<Lesson> Parse(string html, DateTime today, Action<string>? warn = null)
    {
        var table = new HtmlParser().ParseDocument(html).QuerySelector("#CCADynamicCalendarTable")
            ?? throw new ParseFailureException("V HTML chybí #CCADynamicCalendarTable.");

        var rows = RowsOf(table).ToList();
        if (rows.Count < 2) throw new ParseFailureException("Tabulka nemá hlavičku a řádky dnů.");

        var slots = ParseSlots(rows[0]);   // index sloupce -> (start, konec)
        var lessons = new List<Lesson>();
        var days = 0;
        var date = 0;

        foreach (var row in rows.Skip(1))
        {
            var cells = row.Children.Where(c => c.LocalName is "td" or "th").ToList();
            if (cells.Count == 0) continue;

            // Den má v HTML více <tr> (rowspan na <th>): suplování/přesuny žijí v dalších "vrstvách" téhož dne.
            // <th> je jen v prvním řádku dne; další řádky pokračují od sloupce 0.
            if (cells[0].LocalName == "th")
            {
                var m = DayMonth.Match(cells[0].QuerySelector(".KuvHeaderText")?.TextContent ?? "");
                if (!m.Success) throw new ParseFailureException($"Nečitelná hlavička dne: '{cells[0].TextContent.Trim()}'.");
                date = ResolveDate(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), today);
                days++;
                cells.RemoveAt(0);
            }
            if (date == 0) throw new ParseFailureException("Řádek hodin před řádkem s datem dne.");

            var col = 0; // aktuální sloupec = součet colspanů dosud zpracovaných buněk
            foreach (var td in cells)
            {
                var span = int.TryParse(td.GetAttribute("colspan"), out var cs) && cs > 0 ? cs : 1;
                // Fail-loud: přetečení sloupců znamená změnu layoutu; tichá chyba by posunula všechny časy.
                if (col + span > slots.Count)
                    throw new ParseFailureException($"Buňka přesahuje počet hodin ({col}+{span} > {slots.Count}).");

                foreach (var c in td.QuerySelectorAll("table.DctInnerTableType10 td[id]"))
                {
                    var cls = c.ClassList;
                    if (cls.Contains(CssSubstituted) || cls.Contains(CssSchoolEvent)) continue;
                    if (!cls.Contains(CssRegular) && !cls.Contains(CssSubstituting))
                    {
                        warn?.Invoke($"Neznámý typ buňky '{c.ClassName}' ({c.Id}) – přeskočeno.");
                        continue;
                    }

                    var name = c.QuerySelector(".KuvBunkaRozvrhNadpis")?.TextContent.Trim();
                    if (string.IsNullOrEmpty(name))
                    {
                        warn?.Invoke($"Buňka {c.Id} bez zkratky předmětu – přeskočeno.");
                        continue;
                    }

                    // .KuvBunkaRozvrhText = "třída<br>učebna"; TextContent by <br> zahodil a slepil "5.BPCH".
                    var room = SplitOnBr(c.QuerySelector(".KuvBunkaRozvrhText")).ElementAtOrDefault(1)?.Trim() ?? "";

                    lessons.Add(new Lesson(date, name, room, slots[col].Start, slots[col + span - 1].End));
                }
                col += span;
            }
        }

        if (days == 0) throw new ParseFailureException("Rozvrh neobsahuje žádný den.");
        // Prázdný výsledek při korektní struktuře je legitimní (prázdniny) – zapíše se [].
        return lessons.Distinct().OrderBy(l => l.Date).ThenBy(l => l.Start, StringComparer.Ordinal).ToList();
    }

    // Jen řádky samotné tabulky. querySelectorAll("tr") by vrátil i řádky vnořených tabulek v buňkách.
    private static IEnumerable<IElement> RowsOf(IElement table) =>
        table.Children.SelectMany(c => c.LocalName == "tr" ? new[] { c } : c.Children.Where(x => x.LocalName == "tr"));

    private static List<(string Start, string End)> ParseSlots(IElement header)
    {
        var slots = new List<(string Start, string End)>();
        // 1. <th> je prázdný roh tabulky (&nbsp;); hodiny začínají druhým.
        foreach (var th in header.Children.Where(c => c.LocalName == "th").Skip(1))
        {
            var m = TimeRange.Match(th.QuerySelector(".KuvHeaderText")?.TextContent ?? "");
            if (!m.Success) throw new ParseFailureException($"Hlavička sloupce bez času: '{th.TextContent.Trim()}'.");
            slots.Add(($"{int.Parse(m.Groups[1].Value):00}:{m.Groups[2].Value}",
                       $"{int.Parse(m.Groups[3].Value):00}:{m.Groups[4].Value}"));
        }
        if (slots.Count == 0) throw new ParseFailureException("Hlavička neobsahuje žádné hodiny.");
        return slots;
    }

    private static List<string> SplitOnBr(IElement? el)
    {
        var parts = new List<string> { "" };
        if (el is null) return parts;
        foreach (var n in el.ChildNodes)
        {
            if (n is IElement { LocalName: "br" }) parts.Add("");
            else parts[^1] += n.TextContent;
        }
        return parts;
    }

    // Hlavička dne je "21.9." bez roku. Rok = kandidát nejblíže dnešku (řeší přelom roku, týden 29.12.–2.1.).
    private static int ResolveDate(int day, int month, DateTime today)
    {
        if (month is < 1 or > 12) throw new ParseFailureException($"Neplatný měsíc: {day}.{month}.");
        DateTime? best = null;
        foreach (var year in new[] { today.Year - 1, today.Year, today.Year + 1 })
        {
            if (day < 1 || day > DateTime.DaysInMonth(year, month)) continue;
            var cand = new DateTime(year, month, day);
            if (best is null || Math.Abs((cand - today).Days) < Math.Abs((best.Value - today).Days)) best = cand;
        }
        var d = best ?? throw new ParseFailureException($"Neplatné datum: {day}.{month}.");
        return d.Year * 10000 + d.Month * 100 + d.Day;
    }
}
