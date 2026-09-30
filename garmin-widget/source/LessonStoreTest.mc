using Toybox.Test;
using Toybox.StringUtil as SU;

// Offline testy dešifrování a parsování plaintextu -> vnitřní paralelní pole. Spustit:
// monkeyc -t ... a monkeydo ... /t

// (:debug), ne (:test) - test runner by helper spustil jako test.
(:debug)
function toBytes(s) {
    return SU.convertEncodedString(s, {
        :fromRepresentation => SU.REPRESENTATION_STRING_PLAIN_TEXT,
        :toRepresentation => SU.REPRESENTATION_BYTE_ARRAY
    });
}

(:test)
function testLoadPlain(logger) {
    var store = new LessonStore();
    if (!store.loadPlain(toBytes("SOL1,1700000000,2\n20260929,M,PCH,1600,1700\n20260929,AJ,U12,1700,1745\n"))) {
        logger.debug("loadPlain vrátil false");
        return false;
    }
    if (store.scrapedAt() != 1700000000) {
        logger.debug("scrapedAt() = " + store.scrapedAt() + ", čekáno 1700000000");
        return false;
    }
    if (store.entryCount() != 2) {
        logger.debug("entryCount() = " + store.entryCount() + ", čekáno 2");
        return false;
    }
    if (store.dateAt(0) != 20260929 || !store.nameAt(0).equals("M") || !store.roomAt(0).equals("PCH")) {
        logger.debug("záznam 0: " + store.dateAt(0) + " " + store.nameAt(0) + "/" + store.roomAt(0));
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
function testLoadPlainEmpty(logger) {
    var store = new LessonStore();
    if (!store.loadPlain(toBytes("SOL1,1700000000,0\n")) || store.entryCount() != 0) {
        logger.debug("prázdný rozvrh neprošel");
        return false;
    }
    return true;
}

// Šum (= dešifrování špatným klíčem) nesmí přepsat stará data.
(:test)
function testLoadPlainRejectsGarbage(logger) {
    var store = new LessonStore();
    store.loadPlain(toBytes("SOL1,1700000000,1\n20260929,M,PCH,1600,1700\n"));
    if (store.loadPlain(toBytes("xOL1,1700000000,1\n20260929,M,PCH,1600,1700\n"))) {
        logger.debug("špatná hlavička prošla");
        return false;
    }
    if (store.loadPlain(toBytes("SOL1,1700000000,2\n20260929,M,PCH,1600,1700\n"))) {
        logger.debug("useknutý záznam prošel");
        return false;
    }
    if (store.entryCount() != 1 || !store.nameAt(0).equals("M")) {
        logger.debug("neúspěšný parse přepsal stará data");
        return false;
    }
    return true;
}

// Vektor vygenerovaný stejným algoritmem jako scraper/PayloadCrypto.cs (klíč 000102..0f je
// veřejný testovací, ne produkční). Ověřuje nativní AES-CBC, base64, UTF-8 ("Čj") i prázdnou
// učebnu a unix čas scrapu v hlavičce.
(:test)
function testDecryptVector(logger) {
    if (!PayloadCipher.isSupported()) {
        logger.debug("Toybox.Cryptography na tomto zařízení chybí");
        return false;
    }
    var key = SU.convertEncodedString("000102030405060708090a0b0c0d0e0f", {
        :fromRepresentation => SU.REPRESENTATION_STRING_HEX,
        :toRepresentation => SU.REPRESENTATION_BYTE_ARRAY
    });
    var envelope = {
        "v" => 1,
        "iv" => "IP8DIy9F2hxogqi/3gZtkA==",
        "c" => "3iTbEc5X1Rk6nmadcxfrL9WfkbMDCyNmJtphI41YCz18aQJK8PeQuFIAiFDpObeUKnO/2V+5cDv3ncIcYUBM0ugLFyI4Nc8MH7TOWUBPOdAhYsBblk8iAvCRQA/gTvc3"
    };
    var plain = PayloadCipher.decrypt(envelope, key);
    if (plain == null) {
        logger.debug("decrypt vrátil null");
        return false;
    }
    var store = new LessonStore();
    if (!store.loadPlain(plain) || store.entryCount() != 3) {
        logger.debug("dešifrovaný plaintext neprošel parserem");
        return false;
    }
    if (store.scrapedAt() != 1700000000) {
        logger.debug("scrapedAt() = " + store.scrapedAt());
        return false;
    }
    if (!store.nameAt(0).equals("Bicv") || !store.nameAt(1).equals("Čj") || !store.roomAt(1).equals("")
            || store.dateAt(2) != 20261001 || store.startAt(2) != 16 * 60) {
        logger.debug("obsah: " + store.nameAt(0) + "," + store.nameAt(1) + "," + store.roomAt(1) + "," + store.dateAt(2));
        return false;
    }
    return true;
}

(:test)
function testPairedIndex(logger) {
    var store = new LessonStore();
    store.loadPlain(toBytes("SOL1,1700000000,3\n20260930,Bicv,LBi,0800,0935\n20260930,Fcv,LF,0800,0935\n20260930,D,6.C,0945,1030\n"));

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
