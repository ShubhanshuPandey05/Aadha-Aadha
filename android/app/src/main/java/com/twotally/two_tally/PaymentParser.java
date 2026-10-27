package com.twotally.two_tally;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Deliberately conservative English-format detector, not proof of a bank debit. */
public final class PaymentParser {
    public static final String KOTAK_811 = "com.kotak811mobilebankingapp.instantsavingsupiscanandpayrecharge";
    public static final String BHIM = "in.org.npci.upiapp";
    public static final Set<String> PACKAGES = java.util.Collections.unmodifiableSet(new java.util.HashSet<>(java.util.Arrays.asList(
        "com.google.android.apps.nbu.paisa.user", "com.phonepe.app", "net.one97.paytm", KOTAK_811, BHIM)));
    // Bank alerts include OTPs, promotions and mandates, not only completed transfers.
    private static final Pattern SENSITIVE_OR_UNCONFIRMED = Pattern.compile(
        "\\b(OTP|one[ -]time password|verification code|will be|to be|may be|not|mandate|autopay|auto-pay|rejected|reversal)\\b", Pattern.CASE_INSENSITIVE);
    private static final Pattern UPI = Pattern.compile("\\bUPI\\b", Pattern.CASE_INSENSITIVE);
    private static final Pattern BANK_DEBIT = Pattern.compile(
        "\\bdebited\\b", Pattern.CASE_INSENSITIVE);
    private static final Pattern SUCCESSFUL_TRANSFER = Pattern.compile(
        "\\b(?:sent|paid|transferred)\\s+successfully\\s+to\\b|\\b(?:transfer|transaction)\\s+(?:successful|completed)\\b.{0,120}\\bto\\b",
        Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
    private static final Pattern REJECT = Pattern.compile(
        "\\b(received|credited|incoming|refund(?:ed)?|cashback|failed|failure|declined|pending|processing|initiated|unsuccessful|reversed|cancelled|canceled|request(?:ed)?|collect|reminder|due|pay now|scheduled)\\b", Pattern.CASE_INSENSITIVE);
    private static final Pattern OUTGOING = Pattern.compile(
        "\\byou\\s+(?:paid|sent)\\b|\\b(?:paid|sent)\\s+(?:₹|INR\\b|Rs\\b)|(?:₹|INR\\b|Rs\\b).{1,30}\\b(?:paid|sent)\\s+to\\b|\\bpayment\\b.{0,120}\\bto\\b.{0,120}\\b(?:successful|success|completed)\\b|\\bpayment\\s+(?:successful|completed)\\b.{0,120}\\bto\\b",
        Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
    private static final Pattern AMOUNT = Pattern.compile(
        "(?:₹|\\bINR\\b|\\bRs\\.?)\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)(?![0-9.])", Pattern.CASE_INSENSITIVE);
    private static final Pattern REFERENCE = Pattern.compile(
        "\\b(?:UPI\\s*(?:ref(?:erence)?|transaction\\s*id)|UTR|RRN|transaction\\s*(?:id|ref(?:erence)?)|txn\\s*(?:id|ref))\\s*(?:(?:no\\.?|number)\\s*)?[:#.-]?\\s*([A-Za-z0-9]{8,40})\\b",
        Pattern.CASE_INSENSITIVE);
    private static final Pattern RECIPIENT = Pattern.compile(
        "\\bto\\s+(.{1,100}?)(?=\\s+(?:on|via|using|UPI|transaction|txn|UTR|successfully|successful|completed)\\b|[\\n.!]|$)",
        Pattern.CASE_INSENSITIVE);

    public static final class Payment {
        public final Long amountPaise;
        public final String recipient, reference, fingerprint, semantic, eventKey;
        public final long timestamp;
        Payment(Long amount, String recipient, String reference, String fingerprint, String semantic, String eventKey, long timestamp) {
            this.amountPaise = amount; this.recipient = recipient; this.reference = reference;
            this.fingerprint = fingerprint; this.semantic = semantic; this.eventKey = eventKey; this.timestamp = timestamp;
        }
    }

    public static Payment parse(String pkg, String key, String text, long timestamp) {
        if (!PACKAGES.contains(pkg) || text == null || text.length() > 4000) return null;
        boolean addedApp = KOTAK_811.equals(pkg) || BHIM.equals(pkg);
        boolean bankDebit = KOTAK_811.equals(pkg) && UPI.matcher(text).find() && BANK_DEBIT.matcher(text).find();
        boolean outgoing = OUTGOING.matcher(text).find()
            || (addedApp && SUCCESSFUL_TRANSFER.matcher(text).find()) || bankDebit;
        if (REJECT.matcher(text).find() || SENSITIVE_OR_UNCONFIRMED.matcher(text).find() || !outgoing
            || Pattern.compile("\\b(?:to\\s+you|sent\\s+you|paid\\s+you|paid\\s+by)\\b", Pattern.CASE_INSENSITIVE).matcher(text).find()) return null;
        Long amount = null;
        boolean ambiguous = false;
        Matcher amounts = AMOUNT.matcher(text);
        while (amounts.find()) {
            try {
                String token = amounts.group(1);
                if (!token.matches("(?:\\d+|\\d{1,3}(?:,\\d{3})+|\\d{1,2}(?:,\\d{2})*,\\d{3})(?:\\.\\d{1,2})?")) {
                    ambiguous = true; continue;
                }
                long value = new BigDecimal(token.replace(",", "")).movePointRight(2).longValueExact();
                if (value <= 0 || value > 1_000_000_000L || (amount != null && amount != value)) ambiguous = true;
                else amount = value;
            } catch (ArithmeticException | NumberFormatException e) { ambiguous = true; }
        }
        if (ambiguous) amount = null;
        Matcher refs = REFERENCE.matcher(text);
        String ref = refs.find() ? refs.group(1).toUpperCase(Locale.ROOT) : null;
        Matcher recipients = RECIPIENT.matcher(text);
        String recipient = recipients.find() ? recipients.group(1).trim() : null;
        if (recipient != null && recipient.matches("(?i).*(?:₹|\\bINR\\b|\\bRs\\b).*")) recipient = null;
        String normalized = text.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
        String semantic = hash(pkg + "|" + key + "|" + normalized);
        String identity = ref == null ? semantic + "|" + timestamp : "upi|" + ref;
        return new Payment(amount, recipient, ref, hash(identity), semantic, hash(pkg + "|" + key + "|" + timestamp), timestamp);
    }

    public static String hash(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder result = new StringBuilder();
            for (byte b : digest) result.append(String.format(Locale.ROOT, "%02x", b & 255));
            return result.toString();
        } catch (Exception e) { throw new IllegalStateException(e); }
    }
}
