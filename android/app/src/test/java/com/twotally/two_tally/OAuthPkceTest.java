package com.twotally.two_tally;
import org.junit.Test;
import static org.junit.Assert.*;
public class OAuthPkceTest {
    @Test public void callbackUrlsAreValidRfcUris() throws Exception {
        for (String value : new String[]{OAuthPkce.CALLBACK, OAuthPkce.CONFIRMED}) {
            java.net.URI uri = new java.net.URI(value);
            assertTrue(uri.isAbsolute());
            assertEquals("com.twotally.app", uri.getScheme());
            assertEquals("auth", uri.getHost());
            assertNull(uri.getUserInfo());
            assertEquals(-1, uri.getPort());
        }
        assertEquals("/login-callback", new java.net.URI(OAuthPkce.CALLBACK).getPath());
        assertEquals("/confirmed", new java.net.URI(OAuthPkce.CONFIRMED).getPath());
    }
    @Test public void matchesRfc7636ChallengeVector() throws Exception {
        assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            OAuthPkce.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
    }
    @Test public void verifiersAreUniqueAndUrlSafe() {
        String a = OAuthPkce.verifier(), b = OAuthPkce.verifier();
        assertTrue(a.matches("[A-Za-z0-9_-]{43}"));
        assertNotEquals(a, b);
    }
}
