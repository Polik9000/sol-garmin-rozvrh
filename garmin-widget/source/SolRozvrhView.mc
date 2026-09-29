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

    function onUpdate(dc) {
        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_WHITE);
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

        dc.drawText(cx, cy - 85, Gfx.FONT_TINY, "NYNÍ", Gfx.TEXT_JUSTIFY_CENTER);
        if (cur == -1) {
            dc.drawText(cx, cy - 60, Gfx.FONT_MEDIUM, "volno", Gfx.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(cx, cy - 63, Gfx.FONT_MEDIUM,
                combinedName(cur) + "  " + combinedRoom(cur), Gfx.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, cy - 34, Gfx.FONT_TINY,
                minutesToHHMM(_store.startAt(cur)) + "-" + minutesToHHMM(_store.endAt(cur)),
                Gfx.TEXT_JUSTIFY_CENTER);
        }

        dc.drawLine(cx - 60, cy - 10, cx + 60, cy - 10);

        dc.drawText(cx, cy, Gfx.FONT_TINY, "DÁLE", Gfx.TEXT_JUSTIFY_CENTER);
        if (nxt == -1) {
            dc.drawText(cx, cy + 20, Gfx.FONT_SMALL, "nic dalšího", Gfx.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(cx, cy + 20, Gfx.FONT_MEDIUM,
                combinedName(nxt) + "  " + combinedRoom(nxt), Gfx.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, cy + 48, Gfx.FONT_TINY, minutesToHHMM(_store.startAt(nxt)),
                Gfx.TEXT_JUSTIFY_CENTER);
        }

        dc.drawText(cx, cy + 70, Gfx.FONT_XTINY, syncStatusText(),
            Gfx.TEXT_JUSTIFY_CENTER);
    }

    // Sudý/lichý týden - dvě souběžné hodiny ve stejný čas se zobrazí jako "A/B".
    function combinedName(i) {
        var p = _store.pairedIndex(i);
        if (p == -1) { return _store.nameAt(i); }
        var a = i < p ? i : p;
        var b = i < p ? p : i;
        return _store.nameAt(a) + "/" + _store.nameAt(b);
    }

    function combinedRoom(i) {
        var p = _store.pairedIndex(i);
        if (p == -1) { return _store.roomAt(i); }
        var a = i < p ? i : p;
        var b = i < p ? p : i;
        return _store.roomAt(a) + "/" + _store.roomAt(b);
    }

    function firstRunMessage() {
        var status = _store.status();
        if (status.equals("no_phone")) {
            return "Připoj telefon";
        }
        if (status.equals("error")) {
            return "Chyba sítě";
        }
        return "Načítání...";
    }

    // Vždy popisuje stáří dat, která se skutečně zobrazují - ne jen výsledek
    // posledního pokusu o fetch. Selhaný sync tak nikdy nesmaže platné staré info.
    // Krátké zprávy - dlouhý text (např. "Aktualizováno před 6 min") se na kulatém
    // displeji ořízne po stranách, i když se posune nahoru/dolů.
    function syncStatusText() {
        var status = _store.status();
        var last = _store.lastFetch();
        var age = "";
        if (last != null) {
            var ageMin = (Time.now().value() - last) / 60;
            age = (ageMin < 1) ? "teď" : (ageMin.toString() + " min");
        }
        if (status.equals("no_phone")) {
            if (last != null) { return "bez tel. (" + age + ")"; }
            return "bez telefonu";
        }
        if (status.equals("error")) {
            if (last != null) { return "chyba sítě (" + age + ")"; }
            return "chyba sítě";
        }
        if (last == null) {
            return "žádná data";
        }
        return "sync " + age;
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
