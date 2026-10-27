package com.twotally.two_tally;
import org.junit.Test;
import static org.junit.Assert.*;
public class PaymentParserTest {
    private static final String GPAY="com.google.android.apps.nbu.paisa.user";
    private PaymentParser.Payment parse(String text) { return PaymentParser.parse(GPAY,"key",text,1700000000000L); }
    @Test public void extractsOutgoing() {
        var payment=parse("You paid ₹350.25 to Riya successfully. UPI Ref: 123456789012");
        assertNotNull(payment); assertEquals(Long.valueOf(35025),payment.amountPaise);
        assertEquals("Riya",payment.recipient); assertEquals("123456789012",payment.reference);
    }
    @Test public void indianGrouping() { assertEquals(Long.valueOf(12345650),parse("Paid INR 1,23,456.50 to Shop").amountPaise); }
    @Test public void rupeesNotation() { assertEquals(Long.valueOf(120000),parse("Sent Rs. 1,200 to Shop").amountPaise); }
    @Test public void spacedRupeeSymbol() { assertEquals(Long.valueOf(35000),parse("Paid ₹ 350 to Shop").amountPaise); }
    @Test public void amountFirst() { assertEquals(Long.valueOf(35000),parse("₹350 paid to Riya").amountPaise); }
    @Test public void missingAmountNeverInvented() { assertNull(parse("You paid to Riya successfully").amountPaise); }
    @Test public void multipleAmountsNeedReview() { assertNull(parse("Paid ₹350 to Shop. Balance ₹500").amountPaise); }
    @Test public void repeatedSameAmountIsOkay() { assertEquals(Long.valueOf(35000),parse("Paid ₹350\nYou paid ₹350 to Shop").amountPaise); }
    @Test public void invalidDecimalNeedsReview() { assertNull(parse("Paid ₹350.125 to Shop").amountPaise); }
    @Test public void invalidGroupingNeedsReview() { assertNull(parse("Paid ₹12,34 to Shop").amountPaise); }
    @Test public void zeroAndTooLargeNeedReview() {
        assertNull(parse("Paid ₹0 to Shop").amountPaise); assertNull(parse("Paid ₹10000001 to Shop").amountPaise);
    }
    @Test public void ignoresNonPayments() {
        for(String text:new String[]{"Received ₹350 from Riya","Riya sent you ₹350","Riya sent ₹350 to you",
          "₹350 paid by Riya","Payment failed. You paid ₹350 to Shop","You paid ₹350 pending",
          "You paid ₹350 refunded","Request: paid ₹350 to Shop","Cashback: you paid ₹350",
          "Payment processing: paid ₹350","Payment initiated: sent ₹350","Pay ₹350 to Shop",
          "Payment successful","Your OTP is 123456","Collect request ₹350"}) assertNull(text,parse(text));
    }
    @Test public void refusesOtherPackages() { assertNull(PaymentParser.parse("com.bank.app","key","Paid ₹350 to Riya",1)); }
    @Test public void referenceDedupesRepostsAndApps() {
        var a=parse("You paid ₹350 to Riya. UPI ref: 123456789012");
        var b=PaymentParser.parse("com.phonepe.app","newKey","Paid ₹350 to Riya. UTR 123456789012",1800000000000L);
        assertEquals(a.fingerprint,b.fingerprint);
    }
    @Test public void noReferenceIdentityIncludesTime() {
        var a=parse("You paid ₹350 to Riya");
        var b=PaymentParser.parse(GPAY,"key","You paid ₹350 to Riya",1800000000000L);
        assertNotEquals(a.fingerprint,b.fingerprint);assertEquals(a.semantic,b.semantic);
    }
    @Test public void updatesKeepEventIdentityWhenReferenceArrivesLater() {
        var a=parse("You paid ₹350 to Riya");
        var b=parse("You paid ₹350 to Riya. UPI Ref: 123456789012");
        assertEquals(a.eventKey,b.eventKey);
    }
    @Test public void successfulOutgoingAcrossTitleAndBody() {
        assertNotNull(parse("Payment successful\n₹350 to Riya"));
    }
    // Synthetic fixtures: real app notification wording still requires device verification.
    @Test public void kotakUpiDebit() {
        var p = PaymentParser.parse(PaymentParser.KOTAK_811, "bank", "Your A/c XX1234 debited by INR 350.25 via UPI to Riya. UPI Ref No: 123456789012", 1);
        assertNotNull(p); assertEquals(Long.valueOf(35025), p.amountPaise);
        assertEquals("Riya", p.recipient); assertEquals("123456789012", p.reference);
    }
    @Test public void bhimSuccessfulTransfer() {
        var p = PaymentParser.parse(PaymentParser.BHIM, "bhim", "₹350 sent successfully to Riya. RRN: 123456789012", 1);
        assertNotNull(p); assertEquals(Long.valueOf(35000), p.amountPaise);
        assertEquals("Riya", p.recipient); assertEquals("123456789012", p.reference);
    }
    @Test public void newAppsSupportExistingOutgoingPatterns() {
        for (String pkg : new String[]{PaymentParser.KOTAK_811, PaymentParser.BHIM})
            assertNotNull(PaymentParser.parse(pkg, "key", "Payment successful\n₹350 to Riya", 1));
    }
    @Test public void bankBalanceAndMissingAmountRequireReview() {
        for (String text : new String[]{"Account debited via UPI", "Account debited INR 350 via UPI. Available balance INR 900"}) {
            var p = PaymentParser.parse(PaymentParser.KOTAK_811, "key", text, 1);
            assertNotNull(p); assertNull(p.amountPaise);
        }
    }
    @Test public void rejectsBankAndBhimNonPayments() {
        for (String pkg : new String[]{PaymentParser.KOTAK_811, PaymentParser.BHIM})
            for (String text : new String[]{"UPI account credited INR 350", "UPI payment failed. Account debited INR 350",
                "Account will be debited INR 350 via UPI", "UPI mandate: account debited INR 350",
                "OTP 123456: You paid INR 350 to Shop", "UPI transaction rejected. You paid INR 350 to Shop",
                "Account has not been debited INR 350 via UPI", "You paid INR 350 to Shop. Reversal completed",
                "Request: INR 350 sent successfully to Shop", "INR 350 sent successfully to you",
                "Account debited INR 350 for bank charges", "UPI transaction successful"})
                assertNull(pkg + ": " + text, PaymentParser.parse(pkg, "key", text, 1));
    }
    @Test public void bankDebitPatternIsScopedToKotak() {
        assertNull(PaymentParser.parse(GPAY, "key", "Account debited INR 350 via UPI", 1));
    }
    @Test public void kotakAndBhimShareReferenceDeduplication() {
        var a = PaymentParser.parse(PaymentParser.KOTAK_811, "bank", "Account debited INR 350 via UPI. UPI Ref No: 123456789012", 1);
        var b = PaymentParser.parse(PaymentParser.BHIM, "bhim", "Paid INR 350 to Shop. RRN: 123456789012", 2);
        assertEquals(a.fingerprint, b.fingerprint);
    }
}
