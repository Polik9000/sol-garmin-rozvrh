using Toybox.Communications as Comm;
using Toybox.Application.Storage as Store;
using Toybox.WatchUi as Ui;
using Toybox.Time as Time;
using Toybox.Time.Gregorian as Gregorian;

// UPRAV na skutečný endpoint z fáze 2:
const ROZVRH_URL = "https://polik9000.github.io/sol-garmin-rozvrh/rozvrh.json";
// ŠOL se scrapuje po 30 min (fáze 2) - častější dotazy jen plýtvají baterií a daty.
const CACHE_TTL_SEC = 600;

class LessonStore {

    var _dates;
    var _names;
    var _rooms;
    var _starts;
    var _ends;
    var _lastFetch;
    var _status; // "loading" | "ok" | "no_phone" | "error"

    function initialize() {
        _dates = [];
        _names = [];
        _rooms = [];
        _starts = [];
        _ends = [];
        _lastFetch = null;
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
    }

    function saveToStorage() {
        // delete pred set - viz architektura (dvojitá špička paměti při přepisu)
        Store.deleteValue("lessons");
        Store.setValue("lessons", {
            "d" => _dates, "n" => _names, "u" => _rooms, "s" => _starts, "e" => _ends
        });
        Store.deleteValue("sync");
        Store.setValue("sync", _lastFetch);
    }

    function needsRefresh() {
        if (_lastFetch == null) {
            return true;
        }
        return (Time.now().value() - _lastFetch) > CACHE_TTL_SEC;
    }

    function fetch() {
        var options = {
            :method => Comm.HTTP_REQUEST_METHOD_GET,
            :responseType => Comm.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Comm.makeWebRequest(ROZVRH_URL, null, options, method(:onReceive));
    }

    function onReceive(responseCode, data) {
        if (responseCode == 200 && data != null) {
            compact(data);
            _lastFetch = Time.now().value();
            _status = "ok";
            saveToStorage();
        } else if (responseCode == -104) {
            _status = "no_phone"; // BLE_CONNECTION_UNAVAILABLE - telefon není po ruce
        } else {
            _status = "error";
        }
        Ui.requestUpdate();
    }

    // Array<Dictionary> -> 5 paralelních polí primitiv. "data" je jen lokální
    // parametr téhle funkce, po návratu ho GC může uvolnit - nikde se neuchovává.
    function compact(data) {
        var n = data.size();
        var d = new [n];
        var nm = new [n];
        var rm = new [n];
        var st = new [n];
        var en = new [n];
        for (var i = 0; i < n; i += 1) {
            var item = data[i];
            d[i] = item["d"];
            nm[i] = item["n"];
            rm[i] = item["u"];
            st[i] = parseTime(item["s"]);
            en[i] = parseTime(item["e"]);
        }
        _dates = d;
        _names = nm;
        _rooms = rm;
        _starts = st;
        _ends = en;
    }

    // "08:50" -> 530 (minuty od půlnoci) - levnější na porovnání i na uložení než string
    function parseTime(hhmm) {
        return hhmm.substring(0, 2).toNumber() * 60 + hhmm.substring(3, 5).toNumber();
    }

    // Sledy jsou seřazené (d, s) vzestupně už z fáze 1 -> jeden lineární průchod stačí.
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
        return [cur, nxt];
    }

    function entryCount() { return _dates.size(); }
    function status() { return _status; }
    function lastFetch() { return _lastFetch; }
    function nameAt(i) { return _names[i]; }
    function roomAt(i) { return _rooms[i]; }
    function startAt(i) { return _starts[i]; }
    function endAt(i) { return _ends[i]; }
}
