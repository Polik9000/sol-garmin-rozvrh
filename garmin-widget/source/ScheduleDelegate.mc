using Toybox.WatchUi as Ui;

// UP/DOWN scrolluje, START vynutí nový fetch, BACK zavře detail zpět na widget.
class ScheduleDelegate extends Ui.BehaviorDelegate {

    var _view;

    function initialize(view) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onNextPage() {
        _view.scroll(1);
        return true;
    }

    function onPreviousPage() {
        _view.scroll(-1);
        return true;
    }

    function onSelect() {
        _view.forceRefresh();
        return true;
    }

    function onBack() {
        Ui.popView(Ui.SLIDE_RIGHT);
        return true;
    }
}
