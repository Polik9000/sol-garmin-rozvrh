using Toybox.WatchUi as Ui;

class SolRozvrhDelegate extends Ui.BehaviorDelegate {

    var _view;

    function initialize(view) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    // Select/Enter na widgetu vynutí fetch bez ohledu na TTL cache.
    function onSelect() {
        _view.forceRefresh();
        return true;
    }
}
