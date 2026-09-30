using Toybox.Application.Properties as Props;
using Toybox.StringUtil as SU;
using Toybox.Lang as Lang;

// Dešifrování obálky {"v":1,"iv":b64,"c":b64} z scraper/PayloadCrypto.cs.
// AES-128-CBC běží nativně (Toybox.Cryptography, API 3.0.0) - v Monkey C se počítá jen
// base64 dekódování (taky nativní, StringUtil) a lineární parsování plaintextu v LessonStore.
module PayloadCipher {

    const KEY_PROPERTY = "aesKey";

    // Cryptography je volitelný modul (závisí na zařízení/firmwaru) - bez něj widget
    // místo pádu ukáže "Chybí krypto".
    function isSupported() {
        return (Toybox has :Cryptography);
    }

    // 32 hex znaků -> 16B ByteArray, jinak null. Přednost má nastavení aplikace (Garmin Connect,
    // jen pro instalaci ze Storu); jinak klíč zapečený při buildu v source/Secret.mc (sideload
    // přes kabel, soubor je v .gitignore - viz README).
    function keyFromSettings() {
        var hex = Props.getValue(KEY_PROPERTY);
        if (!(hex instanceof Lang.String) || hex.length() != 32) {
            hex = $.AES_KEY_HEX; // globální konstanta ze source/Secret.mc
        }
        if (!(hex instanceof Lang.String) || hex.length() != 32) {
            return null;
        }
        try {
            return SU.convertEncodedString(hex.toLower(), {
                :fromRepresentation => SU.REPRESENTATION_STRING_HEX,
                :toRepresentation => SU.REPRESENTATION_BYTE_ARRAY
            });
        } catch (ex) {
            return null; // ne-hex znaky
        }
    }

    // Vrací ByteArray plaintextu (včetně PKCS7 paddingu - ten ignoruje parser), nebo null.
    function decrypt(envelope, key) {
        if (envelope["v"] != 1 || !(envelope["iv"] instanceof Lang.String) || !(envelope["c"] instanceof Lang.String)) {
            return null;
        }
        try {
            var iv = b64(envelope["iv"]);
            var ct = b64(envelope["c"]);
            if (iv.size() != 16 || ct.size() == 0 || ct.size() % 16 != 0) {
                return null;
            }
            var cipher = new Toybox.Cryptography.Cipher({
                :algorithm => Toybox.Cryptography.CIPHER_AES128,
                :mode => Toybox.Cryptography.MODE_CBC,
                :key => key,
                :iv => iv
            });
            return cipher.decrypt(ct);
        } catch (ex) {
            return null;
        }
    }

    function b64(s) {
        return SU.convertEncodedString(s, {
            :fromRepresentation => SU.REPRESENTATION_STRING_BASE64,
            :toRepresentation => SU.REPRESENTATION_BYTE_ARRAY
        });
    }
}
