using Toybox.Test;

// Offline testy transformace JSON -> vnitřní paralelní pole. Spustit:
// monkeyc -t ... a monkeydo ... /t
(:test)
function testCompact(logger) {
    var store = new LessonStore();
    var data = [
        { "d" => 20260929, "n" => "M", "u" => "PCH", "s" => "16:00", "e" => "17:00" },
        { "d" => 20260929, "n" => "AJ", "u" => "U12", "s" => "17:00", "e" => "17:45" },
    ];
    store.compact(data);

    if (store.entryCount() != 2) {
        logger.debug("entryCount() = " + store.entryCount() + ", čekáno 2");
        return false;
    }
    if (!store.nameAt(0).equals("M") || !store.roomAt(0).equals("PCH")) {
        logger.debug("záznam 0: " + store.nameAt(0) + "/" + store.roomAt(0));
        return false;
    }
    if (store.startAt(0) != 16 * 60 || store.endAt(0) != 17 * 60) {
        logger.debug("časy 0: " + store.startAt(0) + "-" + store.endAt(0));
        return false;
    }
    if (!store.nameAt(1).equals("AJ") || store.startAt(1) != 17 * 60 || store.endAt(1) != 17 * 60 + 45) {
        logger.debug("záznam 1 neodpovídá");
        return false;
    }
    return true;
}

(:test)
function testCompactEmpty(logger) {
    var store = new LessonStore();
    store.compact([]);
    if (store.entryCount() != 0) {
        logger.debug("entryCount() pro prázdná data = " + store.entryCount());
        return false;
    }
    return true;
}

(:test)
function testPairedIndex(logger) {
    var store = new LessonStore();
    var data = [
        { "d" => 20260930, "n" => "Bicv", "u" => "LBi", "s" => "08:00", "e" => "09:35" },
        { "d" => 20260930, "n" => "Fcv", "u" => "LF", "s" => "08:00", "e" => "09:35" },
        { "d" => 20260930, "n" => "D", "u" => "6.C", "s" => "09:45", "e" => "10:30" },
    ];
    store.compact(data);

    if (store.pairedIndex(0) != 1 || store.pairedIndex(1) != 0) {
        logger.debug("pairedIndex pro souběžnou dvojici selhalo: " + store.pairedIndex(0) + "/" + store.pairedIndex(1));
        return false;
    }
    if (store.pairedIndex(2) != -1) {
        logger.debug("pairedIndex(2) mělo být -1, je " + store.pairedIndex(2));
        return false;
    }
    return true;
}
