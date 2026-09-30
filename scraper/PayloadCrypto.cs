using System.Security.Cryptography;
using System.Text;

namespace SolScraper;

/// Šifrovaná obálka pro veřejné GitHub Pages. Hodinky neumí parsovat JSON ze stringu, proto:
///   obálka  = JSON {"v":1,"iv":b64,"c":b64}  -> parsuje ji nativně Communications (CONTENT_TYPE_JSON)
///   plaintext = "SOL1,<počet>\n" + "yyyyMMdd,předmět,učebna,HHMM,HHMM\n" * počet
/// Plaintext je řádkový formát, který widget projde jedním lineárním průchodem nad ByteArray.
/// Magický prefix "SOL1" slouží na hodinkách k detekci špatného klíče (CBC s cizím klíčem = šum).
public static class PayloadCrypto
{
    public const int Version = 1;

    /// SOL_AES_KEY: 32 hex znaků = 128 bitů. AES-128 je na Connect IQ nejlépe podporovaná varianta.
    public static byte[] ParseKey(string hex)
    {
        byte[] key;
        try { key = Convert.FromHexString(hex.Trim()); }
        catch (FormatException) { throw new ArgumentException("SOL_AES_KEY není platný hex řetězec."); }
        if (key.Length != 16) throw new ArgumentException($"SOL_AES_KEY musí mít 32 hex znaků (16 B), má {key.Length} B.");
        return key;
    }

    public static string Serialize(IReadOnlyList<Lesson> lessons)
    {
        var sb = new StringBuilder();
        sb.Append("SOL1,").Append(lessons.Count).Append('\n');
        foreach (var l in lessons)
        {
            sb.Append(l.Date).Append(',')
              .Append(Clean(l.Name)).Append(',')
              .Append(Clean(l.Room)).Append(',')
              .Append(l.Start.Replace(":", "")).Append(',')
              .Append(l.End.Replace(":", "")).Append('\n');
        }
        return sb.ToString();
    }

    /// Deterministické IV = HMAC(odvozený klíč, plaintext)[..16]: stejný rozvrh -> stejný soubor, takže
    /// publikace umí přeskočit commit beze změny. Prozrazuje jen "změnilo se / nezměnilo", což je
    /// z historie commitů vidět tak jako tak. Pro IV se používá klíč odvozený, ne AES klíč přímo.
    public static string Encrypt(string plaintext, byte[] key)
    {
        var plain = Encoding.UTF8.GetBytes(plaintext);
        byte[] ivKeyInput = [.. key, .. "sol-iv"u8];
        var ivKey = SHA256.HashData(ivKeyInput);
        var iv = HMACSHA256.HashData(ivKey, plain)[..16];

        using var aes = Aes.Create();
        aes.Key = key;
        var cipher = aes.EncryptCbc(plain, iv, PaddingMode.PKCS7);

        // Ručně, ne JsonSerializer: výchozí encoder escapuje '+' z base64 jako \u002B. Base64 jinak
        // žádné JSON-citlivé znaky nemá. Přesný tvar kontroluje i publikační pojistka (regex).
        return $"{{\"v\":{Version},\"iv\":\"{Convert.ToBase64String(iv)}\",\"c\":\"{Convert.ToBase64String(cipher)}\"}}";
    }

    // Oddělovače formátu nesmí být v datech. Zkratky předmětů/učeben je v praxi nemají, ale jistota.
    private static string Clean(string s) => s.Replace(',', ' ').Replace('\n', ' ').Replace('\r', ' ');
}
