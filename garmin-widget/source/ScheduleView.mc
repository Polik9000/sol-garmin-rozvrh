using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Time as Time;
using Toybox.Timer as Timer;
using Toybox.Time.Gregorian as Gregorian;

// Detailní scrollovatelný rozvrh - otevře se tlačítkem START z widgetu.
// Řádky jsou jen čísla: i >= 0 = hodina s indexem i, -(i+1) = nadpis dne,
// jehož první hodina má index i. Žádné stringy navíc v paměti (64 KB limit).
class ScheduleView extends Ui.View {

    const LIST_TOP = 34;
    const LIST_BOTTOM_MARGIN = 30;

    var _main;
    var _store;
    var _rows;
    var _top;         // index prvního viditelného řádku, null = ještě nenastaveno
    var _visible;     // kolik řádků se vejde - spočítá se v onUpdate podle fontu
    var _rowsFor;     // _lastFetch, pro který jsou _rows spočítané
    var _timer;
    var _rowsDay;     // den, pro který jsou _rows spočítané (minulé dny se vynechávají)

    function initialize(mainView) {
        View.initialize();
        _main = mainView;
        _store = mainView.store();
        _rows = [];
        _top = null;
        _visible = 5;
        _rowsFor = -1;
        _rowsDay = -1;
    }

    function onShow() {
        if (_store.needsRefresh()) {
            _store.fetch();
        }
        // zvýraznění aktuální hodiny se posouvá s časem
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

    function scroll(delta) {
        if (_top == null) { return; }
        var t = _top + delta;
        var maxTop = _rows.size() - _visible;
        if (t > maxTop) { t = maxTop; }
        if (t < 0) { t = 0; }
        if (t != _top) {
            _top = t;
            Ui.requestUpdate();
        }
    }

    function forceRefresh() {
        _store.fetch();
    }

    function today() {
        var g = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        return g.year * 10000 + g.month * 100 + g.day;
    }

    // Přepočítá řádky jen když přišla nová data nebo se změnil den.
    function rebuildRows() {
        var stamp = _store.lastFetch();
        if (stamp == null) { stamp = 0; }
        var t = today();
        if (stamp == _rowsFor && t == _rowsDay && _rows.size() > 0) { return; }
        _rowsFor = stamp;
        _rowsDay = t;

        var n = _store.entryCount();
        var rows = [];
        var lastDate = -1;
        for (var i = 0; i < n; i += 1) {
            var d = _store.dateAt(i);
            if (d < t) { continue; }
            // druhou hodinu ze souběžné dvojice přeskočit - vypíše se v první
            var p = _store.pairedIndex(i);
            if (p != -1 && p < i) { continue; }
            if (d != lastDate) {
                rows.add(-(i + 1));
                lastDate = d;
            }
            rows.add(i);
        }
        _rows = rows;
        _top = null;
    }

    // Úvodní pozice: aktuální (nebo nejbližší další) hodina jako druhý řádek,
    // aby nad ní byl vidět nadpis dne / předchozí hodina.
    function initialTop() {
        var idx = _store.currentAndNext();
        var focus = idx[0] != -1 ? idx[0] : idx[1];
        var p = _store.pairedIndex(focus);
        if (p != -1 && p < focus) { focus = p; }
        var row = 0;
        if (focus != -1) {
            for (var r = 0; r < _rows.size(); r += 1) {
                if (_rows[r] == focus) { row = r; break; }
            }
        }
        var t = row - 1;
        var maxTop = _rows.size() - _visible;
        if (t > maxTop) { t = maxTop; }
        if (t < 0) { t = 0; }
        return t;
    }

    function onUpdate(dc) {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        dc.drawText(cx, 10, Gfx.FONT_XTINY, "ROZVRH", Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, h - 26, Gfx.FONT_XTINY, _main.syncStatusText(),
            Gfx.TEXT_JUSTIFY_CENTER);

        if (_store.entryCount() == 0) {
            dc.drawText(cx, h / 2, Gfx.FONT_SMALL, _main.firstRunMessage(),
                Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
            return;
        }

        rebuildRows();
        if (_rows.size() == 0) {
            dc.drawText(cx, h / 2, Gfx.FONT_SMALL, "žádné hodiny",
                Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
            return;
        }

        var rowH = Gfx.getFontHeight(Gfx.FONT_SMALL) + 2;
        var listBottom = h - LIST_BOTTOM_MARGIN;
        _visible = (listBottom - LIST_TOP) / rowH;
        if (_visible < 1) { _visible = 1; }
        if (_top == null) { _top = initialTop(); }

        var idx = _store.currentAndNext();
        var cur = idx[0];
        var p = _store.pairedIndex(cur);
        if (p != -1 && p < cur) { cur = p; }
        var t = today();
        var nowMin = nowMinutes();

        var y = LIST_TOP;
        var end = _top + _visible;
        if (end > _rows.size()) { end = _rows.size(); }
        for (var r = _top; r < end; r += 1) {
            var v = _rows[r];
            if (v < 0) {
                var i = -v - 1;
                dc.setColor(Gfx.COLOR_BLUE, Gfx.COLOR_TRANSPARENT);
                dc.drawText(cx, y + 2, Gfx.FONT_TINY, dayLabel(_store.dateAt(i), t),
                    Gfx.TEXT_JUSTIFY_CENTER);
                dc.drawLine(cx - 70, y + rowH - 1, cx + 70, y + rowH - 1);
            } else {
                var text = minutesToHHMM(_store.startAt(v)) + " "
                    + _store.combinedName(v) + " " + _store.combinedRoom(v);
                if (v == cur) {
                    dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
                    dc.fillRoundedRectangle(12, y, w - 24, rowH, 6);
                    dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_TRANSPARENT);
                } else if (_store.dateAt(v) == t && _store.endAt(v) <= nowMin) {
                    dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
                } else {
                    dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
                }
                dc.drawText(cx, y, Gfx.FONT_SMALL, text, Gfx.TEXT_JUSTIFY_CENTER);
            }
            y += rowH;
        }

        // šipky, že je nad/pod čím scrollovat
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        if (_top > 0) {
            dc.fillPolygon([[cx - 6, LIST_TOP - 3], [cx + 6, LIST_TOP - 3], [cx, LIST_TOP - 9]]);
        }
        if (end < _rows.size()) {
            var yb = LIST_TOP + _visible * rowH + 2;
            dc.fillPolygon([[cx - 6, yb], [cx + 6, yb], [cx, yb + 6]]);
        }
    }

    function nowMinutes() {
        var g = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        return g.hour * 60 + g.min;
    }

    // 20260929 -> "Dnes" / "Zítra" / "Čt 1.10."
    function dayLabel(d, t) {
        var y = d / 10000;
        var m = (d / 100) % 100;
        var day = d % 100;
        var dm = day.toString() + "." + m.toString() + ".";
        if (d == t) { return "Dnes " + dm; }
        // poledne, ať posun časového pásma nepřehodí den
        var mom = Gregorian.moment({ :year => y, :month => m, :day => day, :hour => 12 });
        var info = Gregorian.info(mom, Time.FORMAT_SHORT);
        var tomorrow = Gregorian.info(Time.now().add(new Time.Duration(86400)), Time.FORMAT_SHORT);
        if (tomorrow.year * 10000 + tomorrow.month * 100 + tomorrow.day == d) {
            return "Zítra " + dm;
        }
        var names = ["Ne", "Po", "Út", "St", "Čt", "Pá", "So"];
        return names[info.day_of_week - 1] + " " + dm;
    }
}
