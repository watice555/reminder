const { test } = require('node:test');
const assert = require('node:assert/strict');

const env = {
  NUTSTORE_USERNAME: 'test@example.com',
  NUTSTORE_APP_PASSWORD: 'fake-app-password',
  PROBE_TOKEN: 'a-test-token-with-at-least-32-characters',
};
function request(token = env.PROBE_TOKEN, origin = 'https://probe.example') {
  return new Request('https://probe.example/test', {
    method: 'POST', headers: { Origin: origin }, body: new URLSearchParams({ token }),
  });
}
const load = () => import('../webdav-probe/worker.mjs');

test('probe authenticates and uses only fixed read-only depth-zero WebDAV request', async () => {
  const { handleRequest } = await load();
  let calls = 0;
  const response = await handleRequest(request(), env, async (url, options) => {
    calls++;
    assert.equal(url, 'https://dav.jianguoyun.com/dav/');
    assert.equal(options.method, 'PROPFIND');
    assert.equal(options.headers.Depth, '0');
    assert.equal(options.redirect, 'manual');
    assert.equal(options.headers.Authorization, `Basic ${Buffer.from(`${env.NUTSTORE_USERNAME}:${env.NUTSTORE_APP_PASSWORD}`).toString('base64')}`);
    return new Response('private metadata must not be exposed', { status: 207 });
  });
  assert.equal(calls, 1);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  const result = await response.json();
  assert.equal(result.ok, true);
  assert.ok(!JSON.stringify(result).includes('private metadata'));
});

test('invalid credentials, origins, configuration and oversized bodies never contact upstream', async () => {
  const { handleRequest } = await load();
  const forbidden = () => { assert.fail('must not contact upstream'); };
  for (const [req, config, status] of [
    [request('wrong'), env, 401],
    [request('', 'https://other.example'), env, 403],
    [request('', 'null'), env, 403],
    [request(), {}, 503],
    [request(), { ...env, PROBE_TOKEN: 'short' }, 503],
    [request('x'.repeat(5000)), env, 413],
    [new Request('https://probe.example/test'), env, 405],
    [new Request('https://probe.example/other'), env, 404],
  ]) {
    assert.equal((await handleRequest(req, config, forbidden)).status, status);
  }
});

test('upstream errors and redirects are not reported as success or leaked', async () => {
  const { handleRequest } = await load();
  for (const status of [200, 301, 401, 403, 429, 500]) {
    const response = await handleRequest(request(), env, async () => new Response('secret diagnostic', { status }));
    assert.equal(response.status, 502);
    const result = await response.json();
    assert.equal(result.ok, false);
    assert.equal(result.upstreamStatus, status);
    assert.ok(!JSON.stringify(result).includes('secret diagnostic'));
  }
});

test('network failures and timeouts return safe errors', async () => {
  const { handleRequest } = await load();
  for (const error of [new Error('secret credential'), new DOMException('timed out', 'TimeoutError')]) {
    const response = await handleRequest(request(), env, async () => { throw error; });
    assert.equal(response.status, 502);
    assert.equal((await response.json()).ok, false);
  }
});

test('test page needs no third-party scripts and cannot be framed', async () => {
  const { handleRequest } = await load();
  const response = await handleRequest(new Request('https://probe.example/'), {});
  assert.equal(response.status, 200);
  assert.match(response.headers.get('Content-Security-Policy'), /frame-ancestors 'none'/);
  const html = await response.text();
  assert.match(html, /type="password"/);
  assert.match(html, /method="post" action="\/test"/);
  assert.ok(!html.includes('<script'));
});
