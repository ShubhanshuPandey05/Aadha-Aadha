# Google sign-in setup

The app uses the system browser, Supabase Auth, and PKCE. It needs a **Web application** OAuth client, even though Two Tally itself is an Android app. No additional Google mobile SDK or Android SHA-1 client is required for this implementation.

1. Open Google Auth Platform in the personal `two-tally` project.
2. Configure branding/support contact and External audience if prompted. Request only basic identity scopes (`openid`, email, profile). If the consent screen uses a testing audience, add the two friends as test users when required.
3. Create a Web application OAuth client named `Two Tally Supabase`.
4. Leave JavaScript origins empty. Add this exact authorized redirect URI:
   `https://xfzxyercvymggeppygnu.supabase.co/auth/v1/callback`
5. Download the client JSON. Keep its secret out of source control, chat, and APKs. Configure its client ID and secret in Supabase Authentication > Sign In / Providers > Google, then enable Google.

The separate Supabase-to-Android redirect is `com.twotally.app://auth/login-callback`. It is already allowlisted in Supabase. Email confirmations use `com.twotally.app://auth/confirmed`; open these on a phone with the updated app installed, then sign in with email/password. Previously issued or consumed confirmation links may need to be replaced.

Native code keeps the PKCE verifier in encrypted storage for ten minutes, exchanges the callback code with Supabase, and stores the resulting session in the same encrypted store used by background uploads. It never accepts browser-supplied access tokens as a session. Existing signed-in users must use the same account to resume queued uploads. Google names are used for newly created profiles.

## Device checks

- Tap Continue with Google, choose an account, and verify the app returns to group setup or the ledger.
- Cancel in the browser and verify the user can retry.
- Switch away during sign-in and return; test a cold app launch from the callback.
- Try an expired callback; it must not create a session.
- Confirm email on the phone and sign in; no localhost page should be used for newly issued links.
- Confirm a payment and verify background sync still works after restarting the app.

Reference: [Supabase Google sign-in](https://supabase.com/docs/guides/auth/social-login/auth-google).
