package com.twotally.two_tally;

import org.junit.Test;
import static org.junit.Assert.*;

public class PaymentDeduplicationTest {
    private PaymentParser.Payment payment(String text, long time) {
        return PaymentParser.parse(PaymentParser.KOTAK_811, "reused-notification", text, time);
    }
    private boolean duplicate(PaymentParser.Payment next, PaymentParser.Payment previous) {
        return PaymentDeduplication.matches(next, previous.fingerprint, previous.eventKey,
            previous.reference, previous.amountPaise, previous.recipient);
    }
    // Sanitized structure from the user's Kotak notification; no account/name data retained.
    private static final String TEXT = "₹100.00 sent to TEST RECIPIENT\nAmount debited from XX0000. Check out details.";
    @Test public void repeatedPurchaseWithNewTimestampIsNotDuplicate() {
        var first = payment(TEXT, 1000000);
        var next = payment(TEXT, 1030000);
        assertNotNull(first); assertNotNull(next);
        assertEquals(Long.valueOf(10000), next.amountPaise);
        assertFalse(duplicate(next, first));
    }
    @Test public void identicalCallbackIsDuplicate() {
        assertTrue(duplicate(payment(TEXT, 1000000), payment(TEXT, 1000000)));
    }
    @Test public void reusedTimestampWithDifferentAmountIsSeparate() {
        var next = payment(TEXT.replace("100.00", "70.00"), 1000000);
        assertEquals(Long.valueOf(7000), next.amountPaise);
        assertFalse(duplicate(next, payment(TEXT, 1000000)));
    }
    @Test public void differentReferencesOverrideReusedEventMetadata() {
        assertFalse(duplicate(payment(TEXT + " UTR 222222222222", 1000000),
            payment(TEXT + " UTR 111111111111", 1000000)));
    }
    @Test public void referenceAddedToSameEventIsAnUpdate() {
        assertTrue(duplicate(payment(TEXT + " UTR 111111111111", 1000000), payment(TEXT, 1000000)));
    }
    @Test public void sameReferenceRepostedLaterIsDuplicate() {
        assertTrue(duplicate(payment(TEXT + " UTR 111111111111", 2000000),
            payment(TEXT + " UTR 111111111111", 1000000)));
    }
}
