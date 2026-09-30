using Toybox.Application as App;
using Toybox.WatchUi as Ui;

class SolRozvrhApp extends App.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    var _view;

    function getInitialView() {
        _view = new SolRozvrhView();
        return [ _view, new SolRozvrhDelegate(_view) ];
    }

    // Nový AES klíč z Garmin Connect -> hned zkusit stáhnout, ne čekat na TTL cache.
    function onSettingsChanged() {
        if (_view != null) {
            _view.forceRefresh();
        }
    }
}
