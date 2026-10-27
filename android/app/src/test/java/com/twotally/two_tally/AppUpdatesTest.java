package com.twotally.two_tally;
import org.junit.Test;
import static org.junit.Assert.*;
public class AppUpdatesTest {
    @Test public void comparesNumericVersionsAndRejectsMalformedVersions() {
        assertTrue(AppUpdates.newer("1.0.10","1.0.9"));
        assertTrue(AppUpdates.newer("2.0.0","1.9.9"));
        assertFalse(AppUpdates.newer("1.0.8","1.0.8"));
        assertFalse(AppUpdates.newer("1.0.7","1.0.8"));
        assertFalse(AppUpdates.newer("1.0.9-beta","1.0.8"));
        assertFalse(AppUpdates.newer("999999999999.0.0","1.0.8"));
        assertFalse(AppUpdates.newer("","1.0.8"));
    }
}
