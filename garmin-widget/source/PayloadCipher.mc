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

    // Sideload (mimo Connect IQ Store) nemá Garmin Connect App Settings sync - ověřeno
    // v simulátoru, "Trigger App Settings" v menu Simulation jen simuluje push uvnitř
    // simulátoru, nic nejde exportovat na reálné zařízení. Fallback: soubor
    // garmin-widget/source/Secret.mc (v .gitignore, NIKDY necommitovat!) s obsahem
    // `const AES_KEY_HEX = "<32 hex znaků>";`. Bez něj build selže (undefined symbol) -
    // záměrně: je to čistě osobní build bez distribuce, ne chyba k opravě.
    function localFallbackHex() {
        return AES_KEY_HEX;
    }

    // 32 hex znaků z nastavení aplikace (Garmin Connect), jinak lokální fallback
    // (sideload nemá App Settings sync - viz localFallbackHex) -> 16B ByteArray, jinak null.
    function keyFromSettings() {
        var hex = Props.getValue(KEY_PROPERTY);
        if (!(hex instanceof Lang.String) || hex.length() != 32) {
            hex = localFallbackHex();
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
