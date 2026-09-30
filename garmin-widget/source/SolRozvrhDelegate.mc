using Toybox.WatchUi as Ui;

class SolRozvrhDelegate extends Ui.BehaviorDelegate {

    var _view;

    function initialize(view) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    // START na widgetu otevře detailní scrollovatelný rozvrh (jako u vestavěných
    // widgetů). Vynucený refresh je teď START uvnitř detailu.
    function onSelect() {
        var detail = new ScheduleView(_view);
        Ui.pushView(detail, new ScheduleDelegate(detail), Ui.SLIDE_LEFT);
        return true;
    }
}
