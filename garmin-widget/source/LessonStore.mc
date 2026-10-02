using Toybox.Communications as Comm;
using Toybox.Application.Storage as Store;
using Toybox.Lang as Lang;
using Toybox.StringUtil as SU;
using Toybox.WatchUi as Ui;
using Toybox.Time as Time;
using Toybox.Time.Gregorian as Gregorian;

// Obsah je AES-128-CBC obálka {"v":1,"iv":b64,"c":b64} - veřejná URL nevadí (viz README "Zabezpečení").
const ROZVRH_URL = "https://polik9000.github.io/sol-garmin-rozvrh/rozvrh.json";
// ŠOL se scrapuje po 30 min (fáze 2) - častější dotazy jen plýtvají baterií a daty.
const CACHE_TTL_SEC = 600;

class LessonStore {

    var _dates;
    var _names;
    var _rooms;
    var _starts;
    var _ends;
    var _lastFetch;  // kdy hodinky naposledy úspěšně stáhly z GitHub Pages (pro TTL cache)
    var _scrapedAt;  // kdy scraper reálně stáhl data ze ŠOL (pro zobrazení stáří dat uživateli)
    var _status; // "loading" | "ok" | "no_phone" | "error" | "no_key" | "bad_key" | "no_crypto"

    function initialize() {
        _dates = [];
        _names = [];
        _rooms = [];
        _starts = [];
        _ends = [];
        _lastFetch = null;
        _scrapedAt = null;
        _status = "loading";
        loadFromStorage();
    }

    function loadFromStorage() {
        var bundle = Store.getValue("lessons");
        if (bundle != null) {
            _dates = bundle["d"];
            _names = bundle["n"];
            _rooms = bundle["u"];
            _starts = bundle["s"];
            _ends = bundle["e"];
            _status = "ok";
        }
        var t = Store.getValue("sync");
        if (t != null) {
            _lastFetch = t;
        }
        var sc = Store.getValue("scraped");
        if (sc != null) {
            _scrapedAt = sc;
        }
    }

    function saveToStorage() {
        // delete pred set - viz architektura (dvojitá špička paměti při přepisu)
        Store.deleteValue("lessons");
        Store.setValue("lessons", {
            "d" => _dates, "n" => _names, "u" => _rooms, "s" => _starts, "e" => _ends
        });
        Store.deleteValue("sync");
        Store.setValue("sync", _lastFetch);
        Store.deleteValue("scraped");
        Store.setValue("scraped", _scrapedAt);
    }

    function needsRefresh() {
        if (_lastFetch == null) {
            return true;
        }
        return (Time.now().value() - _lastFetch) > CACHE_TTL_SEC;
    }

    function fetch() {
        if (PayloadCipher.keyFromSettings() == null) {
            _status = "no_key"; // nemá smysl tahat data, která neumíme přečíst
            Ui.requestUpdate();
            return;
        }
        var options = {
            :method => Comm.HTTP_REQUEST_METHOD_GET,
            :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Comm.makeWebRequest(ROZVRH_URL, null, options, method(:onReceive));
    }

    function onReceive(responseCode, data) {
        if (responseCode == 200 && data instanceof Lang.Dictionary) {
            _status = decryptAndLoad(data);
            if (_status.equals("ok")) {
                _lastFetch = Time.now().value();
                saveToStorage();
            }
        } else if (responseCode == -104) {
            _status = "no_phone"; // BLE_CONNECTION_UNAVAILABLE - telefon není po ruce
        } else {
            _status = "error";
        }
        Ui.requestUpdate();
    }

    // Obálka -> ByteArray plaintextu -> paralelní pole. "data" i mezivýsledky jsou lokální,
    // po návratu je GC uvolní. Při jakémkoli selhání zůstávají stará data nedotčená.
    function decryptAndLoad(envelope) {
        if (!PayloadCipher.isSupported()) {
            return "no_crypto";
        }
        var key = PayloadCipher.keyFromSettings();
        if (key == null) {
            return "no_key";
        }
        var plain = PayloadCipher.decrypt(envelope, key);
        if (plain == null || !loadPlain(plain)) {
            return "bad_key"; // špatný klíč dá šum -> neprojde kontrolou hlavičky "SOL1"
        }
        return "ok";
    }

    // Formát (viz scraper/PayloadCrypto.cs): "SOL1,<unix čas scrapu>,<n>\n" +
    // n× "yyyyMMdd,předmět,učebna,HHMM,HHMM\n". Jeden lineární průchod nad ByteArray,
    // žádný String.find/substring na celém textu. Konec se řídí počtem záznamů, ne
    // délkou - PKCS7 padding za posledním řádkem se ignoruje.
    function loadPlain(b) {
        var len = b.size();
        // 'S','O','L','1',','
        if (len < 7 || b[0] != 83 || b[1] != 79 || b[2] != 76 || b[3] != 49 || b[4] != 44) {
            return false;
        }
        var hdr0 = scanTo(b, 5, 44); // čárka za unix časem scrapu
        if (hdr0 < 0) { return false; }
        var epoch = parseNum(b, 5, hdr0);
        if (epoch < 0) { return false; }
        var end = scanTo(b, hdr0 + 1, 10);
        if (end < 0) { return false; }
        var n = parseNum(b, hdr0 + 1, end);
        if (n < 0) { return false; }
        var pos = end + 1;

        var d = new [n];
        var nm = new [n];
        var rm = new [n];
        var st = new [n];
        var en = new [n];
        for (var i = 0; i < n; i += 1) {
            var e0 = scanTo(b, pos, 44);
            if (e0 < 0) { return false; }
            var e1 = scanTo(b, e0 + 1, 44);
            if (e1 < 0) { return false; }
            var e2 = scanTo(b, e1 + 1, 44);
            if (e2 < 0) { return false; }
            var e3 = scanTo(b, e2 + 1, 44);
            if (e3 < 0) { return false; }
            var e4 = scanTo(b, e3 + 1, 10);
            if (e4 < 0) { return false; }

            var s = parseNum(b, e2 + 1, e3);
            var e = parseNum(b, e3 + 1, e4);
            d[i] = parseNum(b, pos, e0);
            if (d[i] < 0 || s < 0 || e < 0) { return false; }
            nm[i] = bytesToString(b, e0 + 1, e1);
            rm[i] = bytesToString(b, e1 + 1, e2);
            st[i] = (s / 100) * 60 + s % 100; // HHMM -> minuty od půlnoci
            en[i] = (e / 100) * 60 + e % 100;
            pos = e4 + 1;
        }
        _dates = d;
        _names = nm;
        _rooms = rm;
        _starts = st;
        _ends = en;
        _scrapedAt = epoch;
        return true;
    }

    // Index prvního výskytu bajtu "ch" od "from", nebo -1.
    function scanTo(b, from, ch) {
        var len = b.size();
        for (var i = from; i < len; i += 1) {
            if (b[i] == ch) { return i; }
        }
        return -1;
    }

    // Dekadické číslo z bajtů [from, to). -1 pro prázdný úsek nebo ne-číslici.
    function parseNum(b, from, to) {
        if (to <= from) { return -1; }
        var v = 0;
        for (var i = from; i < to; i += 1) {
            var c = b[i] - 48;
            if (c < 0 || c > 9) { return -1; }
            v = v * 10 + c;
        }
        return v;
    }

    function bytesToString(b, from, to) {
        if (to <= from) { return ""; }
        return SU.convertEncodedString(b.slice(from, to), {
            :fromRepresentation => SU.REPRESENTATION_BYTE_ARRAY,
            :toRepresentation => SU.REPRESENTATION_STRING_PLAIN_TEXT,
            :encoding => SU.CHAR_ENCODING_UTF8
        });
    }

    // Sledy jsou seřazené (d, s) vzestupně už z fáze 1 -> jeden lineární průchod stačí.
    // Vrací [cur, nxt, today, nowMin, day_of_week] - den v týdnu 1=neděle..7=sobota (Garmin konvence).
    function currentAndNext() {
        var g = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var today = g.year * 10000 + g.month * 100 + g.day;
        var nowMin = g.hour * 60 + g.min;
        var cur = -1;
        var nxt = -1;
        var n = _dates.size();
        for (var i = 0; i < n; i += 1) {
            if (_dates[i] < today) {
                continue;
            }
            if (_dates[i] == today) {
                if (_starts[i] <= nowMin && nowMin < _ends[i]) {
                    cur = i;
                }
                if (_starts[i] > nowMin && nxt == -1) {
                    nxt = i;
                }
            } else if (nxt == -1) {
                nxt = i; // první hodina prvního budoucího dne v cache
            }
        }
        return [cur, nxt, today, nowMin, g.day_of_week];
    }

    // Minuty od teď do zadaného data (yyyyMMdd) a minuty od půlnoci - může vyjít i záporně
    // (v minulosti) nebo přes více dní dopředu (napr. hodina příští týden).
    // Gregorian.moment() bere vstup jako UTC, ne místní čas -> přímé porovnání s Time.now()
    // by bylo posunuté o offset časové zóny (v ČR +1/+2 h). Proto se z moment() bere jen
    // rozdíl dní (oba konce v UTC, offset se vyruší) a minuty se počítají z místního času.
    function minutesUntil(dateInt, minuteOfDay) {
        var g = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var todayNoon = Gregorian.moment({ :year => g.year, :month => g.month, :day => g.day, :hour => 12 });
        var targetNoon = Gregorian.moment({
            :year => dateInt / 10000, :month => (dateInt / 100) % 100, :day => dateInt % 100, :hour => 12
        });
        var days = (targetNoon.value() - todayNoon.value()) / 86400;
        return days * 1440 + minuteOfDay - (g.hour * 60 + g.min);
    }

    function entryCount() { return _dates.size(); }
    function status() { return _status; }
    function lastFetch() { return _lastFetch; }
    function scrapedAt() { return _scrapedAt; }
    function dateAt(i) { return _dates[i]; }
    function nameAt(i) { return _names[i]; }
    function roomAt(i) { return _rooms[i]; }
    function startAt(i) { return _starts[i]; }
    function endAt(i) { return _ends[i]; }

    // Sudý/lichý týden apod.: dvě hodiny ve stejný čas téhož dne (sousední indexy
    // díky řazení podle (d,s)). Vrátí index té druhé, nebo -1.
    function pairedIndex(i) {
        if (i == -1) { return -1; }
        if (i > 0 && _dates[i - 1] == _dates[i] && _starts[i - 1] == _starts[i]) {
            return i - 1;
        }
        if (i + 1 < _dates.size() && _dates[i + 1] == _dates[i] && _starts[i + 1] == _starts[i]) {
            return i + 1;
        }
        return -1;
    }

    // Sudý/lichý týden - dvě souběžné hodiny ve stejný čas se zobrazí jako "A/B".
    function combinedName(i) {
        var p = pairedIndex(i);
        if (p == -1) { return _names[i]; }
        var a = i < p ? i : p;
        var b = i < p ? p : i;
        return _names[a] + "/" + _names[b];
    }

    function combinedRoom(i) {
        var p = pairedIndex(i);
        if (p == -1) { return _rooms[i]; }
        var a = i < p ? i : p;
        var b = i < p ? p : i;
        return _rooms[a] + "/" + _rooms[b];
    }
}

function minutesToHHMM(m) {
    var h = m / 60;
    var mm = m % 60;
    var hs = h.toString();
    if (h < 10) { hs = "0" + hs; }
    var ms = mm.toString();
    if (mm < 10) { ms = "0" + ms; }
    return hs + ":" + ms;
}
