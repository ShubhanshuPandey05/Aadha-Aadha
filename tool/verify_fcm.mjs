// Read a service-account JSON from stdin; never print credentials or access tokens.
// validate_only verifies FCM authorization without delivering a message.
import { sign } from 'node:crypto';
let input = '';
for await (const chunk of process.stdin) input += chunk;
try {
  const account = JSON.parse(input);
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const unsigned = encode({ alg: 'RS256', typ: 'JWT' }) + '.' + encode({
    iss: account.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600,
  });
  const assertion = unsigned + '.' + sign('RSA-SHA256', Buffer.from(unsigned), account.private_key).toString('base64url');
  const oauth = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }),
    signal: AbortSignal.timeout(20000),
  });
  if (!oauth.ok) throw new Error('OAuth HTTP ' + oauth.status);
  const token = await oauth.json();
  const response = await fetch(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`, {
    method: 'POST', headers: { Authorization: 'Bearer ' + token.access_token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ validate_only: true, message: { topic: 'two-tally-config-validation', data: { check: 'configuration' } } }),
    signal: AbortSignal.timeout(20000),
  });
  if (!response.ok) throw new Error('FCM validation HTTP ' + response.status);
  console.log(JSON.stringify({ project: account.project_id, fcmValidationStatus: response.status, deliveredMessages: 0 }));
} catch {
  console.error('FCM validation failed; credentials and response details withheld.');
  process.exitCode = 1;
}
