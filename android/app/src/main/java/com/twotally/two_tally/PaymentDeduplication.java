package com.twotally.two_tally;

import java.util.Objects;

/** Compare payment evidence, not a time window containing similar purchases. */
final class PaymentDeduplication {
    static boolean matches(PaymentParser.Payment payment, String fingerprint, String eventKey,
                           String reference, Long amount, String recipient) {
        if (payment.fingerprint.equals(fingerprint)) return true;
        // Distinct references are separate transfers, even if the source reuses its notification ID/time.
        if (payment.reference != null && reference != null && !payment.reference.equals(reference)) return false;
        // Same event with the same values may be an update adding the reference later.
        return payment.eventKey.equals(eventKey)
            && Objects.equals(payment.amountPaise, amount)
            && Objects.equals(payment.recipient, recipient);
    }
}
