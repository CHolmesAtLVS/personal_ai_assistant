/**
 * test-openclaw-inference.js
 *
 * Streamed into a running OpenClaw pod via:
 *   kubectl exec -i -n <ns> <pod> -c main -- node - < scripts/test-openclaw-inference.js
 *
 * Uses env vars already present in the pod (AZURE_OPENAI_ENDPOINT, AZURE_AI_API_KEY).
 * Prints PASS:<reply> or FAIL:<reason> to stdout, then exits.
 * Exits 0 regardless — pass/fail is communicated via the output line prefix
 * so the caller (test-openclaw.sh) can distinguish outcomes without relying
 * on exit codes from kubectl exec.
 */

'use strict';

const https = require('https');

const endpoint = process.env.AZURE_OPENAI_ENDPOINT;
const apiKey = process.env.AZURE_AI_API_KEY;

if (!endpoint || !apiKey) {
  console.log('FAIL:missing env vars (AZURE_OPENAI_ENDPOINT or AZURE_AI_API_KEY)');
  process.exit(0);
}

const url =
  endpoint.replace(/\/+$/, '') +
  '/openai/deployments/gpt-5.4-mini/chat/completions?api-version=2024-06-01';

const payload = JSON.stringify({
  messages: [{ role: 'user', content: 'Reply with exactly one word: OK' }],
  max_completion_tokens: 20,
});

const req = https.request(
  url,
  {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'api-key': apiKey,
      'Content-Length': Buffer.byteLength(payload),
    },
  },
  (res) => {
    let body = '';
    res.on('data', (chunk) => { body += chunk; });
    res.on('end', () => {
      if (res.statusCode !== 200) {
        console.log('FAIL:HTTP ' + res.statusCode + ' ' + body.slice(0, 200));
        return;
      }
      try {
        const reply = JSON.parse(body).choices[0].message.content.trim();
        console.log('PASS:' + reply);
      } catch (e) {
        console.log('FAIL:parse error — ' + body.slice(0, 200));
      }
    });
  }
);

req.on('error', (e) => {
  console.log('FAIL:' + e.message);
});

req.setTimeout(30000, () => {
  console.log('FAIL:timeout after 30s');
  req.destroy();
});

req.write(payload);
req.end();
