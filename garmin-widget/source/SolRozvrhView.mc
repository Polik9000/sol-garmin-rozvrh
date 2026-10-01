using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.System as Sys;
using Toybox.Timer as Timer;
using Toybox.Time as Time;

class SolRozvrhView extends Ui.View {

    var _store;
    var _timer;

    function initialize() {
        View.initialize();
        _store = new LessonStore();
    }

    function onShow() {
        // Sledovatel je pryč po dobu, kdy widget není zobrazený - dotaz na
        // datum/čas se přepočítá znovu při každém otevření a Timer to drží živé.
        if (_store.needsRefresh() && Sys.getDeviceSettings().phoneConnected) {
            _store.fetch();
        }
        _timer = new Timer.Timer();
        _timer.start(method(:onTimer), 30000, true);
    }

    function onHide() {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
    }

    function onTimer() {
        Ui.requestUpdate();
    }

    function forceRefresh() {
        _store.fetch();
    }

    function store() {
        return _store;
    }

    function onUpdate(dc) {
        // Tmavý režim - hodinky mají tmavé UI všude jinde.
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2;
        var cy = dc.getHeight() / 2;

        if (_store.entryCount() == 0) {
            dc.drawText(cx, cy, Gfx.FONT_SMALL, firstRunMessage(),
                Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
            return;
        }

        var idx = _store.currentAndNext();
        var cur = idx[0];
        var nxt = idx[1];
        var today = idx[2];
        var dow = idx[4];

        dc.drawText(cx, cy - 85, Gfx.FONT_TINY, "NYNÍ", Gfx.TEXT_JUSTIFY_CENTER);
        if (cur == -1) {
            var free = freeTimeState(nxt, today, dow);
            dc.drawText(cx, cy - 60, Gfx.FONT_MEDIUM, free[0], Gfx.TEXT_JUSTIFY_CENTER);
            if (free[1] != null) {
                dc.drawText(cx, cy - 34, Gfx.FONT_TINY, free[1], Gfx.TEXT_JUSTIFY_CENTER);
            }
        } else {
            dc.drawText(cx, cy - 63, Gfx.FONT_MEDIUM,
                _store.combinedName(cur) + "  " + _store.combinedRoom(cur), Gfx.TEXT_JUSTIFY_CENTER);
            var endIn = _store.minutesUntil(_store.dateAt(cur), _store.endAt(cur));
            dc.drawText(cx, cy - 34, Gfx.FONT_TINY,
                minutesToHHMM(_store.startAt(cur)) + "-" + minutesToHHMM(_store.endAt(cur))
                    + " (za " + formatDuration(endIn) + ")",
                Gfx.TEXT_JUSTIFY_CENTER);
        }

        dc.drawLine(cx - 60, cy - 10, cx + 60, cy - 10);

        dc.drawText(cx, cy, Gfx.FONT_TINY, "DÁLE", Gfx.TEXT_JUSTIFY_CENTER);
        if (nxt == -1) {
            dc.drawText(cx, cy + 20, Gfx.FONT_SMALL, "nic dalšího", Gfx.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(cx, cy + 20, Gfx.FONT_MEDIUM,
                _store.combinedName(nxt) + "  " + _store.combinedRoom(nxt), Gfx.TEXT_JUSTIFY_CENTER);
            var startIn = _store.minutesUntil(_store.dateAt(nxt), _store.startAt(nxt));
            dc.drawText(cx, cy + 48, Gfx.FONT_TINY,
                minutesToHHMM(_store.startAt(nxt)) + " (za " + formatDuration(startIn) + ")",
                Gfx.TEXT_JUSTIFY_CENTER);
        }

        dc.drawText(cx, cy + 70, Gfx.FONT_XTINY, syncStatusText(),
            Gfx.TEXT_JUSTIFY_CENTER);
    }

    // Náhrada za "volno": [popisek, detail-nebo-null]. dow: 1=neděle, 7=sobota (Garmin konvence).
    function freeTimeState(nxt, today, dow) {
        if (dow == 1 || dow == 7) {
            return ["víkend", null];
        }
        if (nxt != -1 && _store.dateAt(nxt) == today) {
            var inMin = _store.minutesUntil(today, _store.startAt(nxt));
            return ["přestávka", "za " + formatDuration(inMin)];
        }
        return ["konec školy", null];
    }

    function firstRunMessage() {
        var status = _store.status();
        if (status.equals("no_phone")) {
            return "Připoj telefon";
        }
        if (status.equals("error")) {
            return "Chyba sítě";
        }
        var keyMsg = keyStatusText(status);
        if (keyMsg != null) {
            return keyMsg;
        }
        return "Načítání...";
    }

    // Vždy popisuje stáří dat, která se skutečně zobrazují - ne jen výsledek
    // posledního pokusu o fetch. Selhaný sync tak nikdy nesmaže platné staré info.
    // scrapedAt() = kdy scraper reálně stáhl data ze ŠOL, ne kdy si je hodinky stáhly
    // z GitHub Pages (lastFetch() - ten řídí jen TTL cache, viz needsRefresh()).
    // Krátké zprávy - dlouhý text (např. "Aktualizováno před 6 min") se na kulatém
    // displeji ořízne po stranách, i když se posune nahoru/dolů.
    function syncStatusText() {
        var status = _store.status();
        var last = _store.scrapedAt();
        var age = "";
        if (last != null) {
            var ageMin = (Time.now().value() - last) / 60;
            age = formatDuration(ageMin);
        }
        if (status.equals("no_phone")) {
            if (last != null) { return "bez tel. (" + age + ")"; }
            return "bez telefonu";
        }
        if (status.equals("error")) {
            if (last != null) { return "chyba sítě (" + age + ")"; }
            return "chyba sítě";
        }
        var keyMsg = keyStatusText(status);
        if (keyMsg != null) {
            return keyMsg;
        }
        if (last == null) {
            return "žádná data";
        }
        return "sync " + age;
    }

    // Stavy dešifrování. Krátké - kulatý displej, viz výše.
    function keyStatusText(status) {
        if (status.equals("no_key")) { return "Zadej klíč"; }
        if (status.equals("bad_key")) { return "Špatný klíč"; }
        if (status.equals("no_crypto")) { return "Chybí krypto"; }
        return null;
    }

    // Kompaktní doba trvání: "Xd Yh" / "Xh Ym" / "Xm" / "teď" - vždy jen dvě nejvyšší
    // jednotky, jinak se text na kulatém displeji nevejde (viz komentář u syncStatusText).
    function formatDuration(totalMin) {
        if (totalMin < 1) { return "teď"; }
        var days = totalMin / 1440;
        var hours = (totalMin % 1440) / 60;
        var mins = totalMin % 60;
        if (days > 0) { return days.toString() + "d " + hours.toString() + "h"; }
        if (hours > 0) { return hours.toString() + "h " + mins.toString() + "m"; }
        return mins.toString() + "m";
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
}
