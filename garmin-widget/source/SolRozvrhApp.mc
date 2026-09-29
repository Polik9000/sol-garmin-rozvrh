using Toybox.Application as App;
using Toybox.WatchUi as Ui;

class SolRozvrhApp extends App.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        var view = new SolRozvrhView();
        return [ view, new SolRozvrhDelegate(view) ];
    }
}
