// Read-only connectivity probe. No task data is downloaded or modified.
const page = `<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>坚果云连接测试</title>
<style>body{font:17px system-ui;max-width:540px;margin:60px auto;padding:20px;line-height:1.7}input,button{font:inherit;padding:10px;box-sizing:border-box;width:100%;margin:8px 0}pre{white-space:pre-wrap}</style>
<h1>坚果云连接测试</h1><p>只检查连接和账号认证，不读取任务内容，不创建或修改文件。</p>
<form method="post" action="/test"><label for="token">中转访问密钥</label><input id="token" name="token" type="password" required autocomplete="off"><button>测试连接</button></form>
<p>请输入你在 Cloudflare 中设置的 PROBE_TOKEN，不是坚果云密码。结果中的 ok 为 true 表示连接和认证成功；尚未验证文件读写或自动同步。</p></html>`;

const headers = {
  'Cache-Control': 'no-store',
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
};

function json(status, value) {
  return new Response(JSON.stringify(value, null, 2), {
    status, headers: { ...headers, 'Content-Type': 'application/json; charset=utf-8' },
  });
}

async function equalToken(a, b) {
  const digest = value => crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  const [left, right] = await Promise.all([digest(a), digest(b)]);
  const x = new Uint8Array(left), y = new Uint8Array(right);
  let difference = 0;
  for (let i = 0; i < x.length; i++) difference |= x[i] ^ y[i];
  return difference === 0;
}

export async function handleRequest(request, env, fetchUpstream = fetch) {
  const url = new URL(request.url);
  if (url.pathname === '/' && request.method === 'GET') {
    return new Response(page, { headers: { ...headers, 'Content-Type': 'text/html; charset=utf-8' } });
  }
  if (url.pathname !== '/test') return json(404, { ok: false, message: '接口不存在。' });
  if (request.method !== 'POST') return json(405, { ok: false, message: '请从测试页面提交。' });
  if (request.headers.get('Origin') !== url.origin) {
    return json(403, { ok: false, message: '请从此中转服务的首页发起测试。' });
  }
  if (!env.NUTSTORE_USERNAME || !env.NUTSTORE_APP_PASSWORD || !env.PROBE_TOKEN || env.PROBE_TOKEN.length < 32) {
    return json(503, { ok: false, message: '请配置三个 Secrets，PROBE_TOKEN 至少 32 个字符。' });
  }
  if (!request.headers.get('Content-Type')?.startsWith('application/x-www-form-urlencoded')) {
    return json(415, { ok: false, message: '请使用测试页面的表单。' });
  }
  // Bound even chunked bodies before parsing; never log the submitted secret.
  const reader = request.body?.getReader();
  if (!reader) return json(400, { ok: false, message: '缺少访问密钥。' });
  let size = 0, body = '';
  const decoder = new TextDecoder();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > 4096) {
      await reader.cancel();
      return json(413, { ok: false, message: '请求过大。' });
    }
    body += decoder.decode(value, { stream: true });
  }
  body += decoder.decode();
  const token = new URLSearchParams(body).get('token') || '';
  if (!await equalToken(token, env.PROBE_TOKEN)) return json(401, { ok: false, message: '中转访问密钥不正确。' });

  const credentialBytes = new TextEncoder().encode(`${env.NUTSTORE_USERNAME}:${env.NUTSTORE_APP_PASSWORD}`);
  const authorization = `Basic ${btoa(Array.from(credentialBytes, byte => String.fromCharCode(byte)).join(''))}`;
  try {
    const response = await fetchUpstream('https://dav.jianguoyun.com/dav/', {
      method: 'PROPFIND',
      headers: { Authorization: authorization, Depth: '0', 'Content-Type': 'application/xml; charset=utf-8' },
      body: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
      redirect: 'manual',
      signal: AbortSignal.timeout(15000),
    });
    // Do not expose account metadata or upstream error bodies to the browser.
    await response.body?.cancel();
    const ok = response.status === 207;
    const messages = {
      401: '坚果云认证失败，请核对账号和专用应用密码。',
      403: '坚果云拒绝访问，请检查账号权限。',
      429: '坚果云请求过于频繁，请稍后重试。',
    };
    return json(ok ? 200 : 502, {
      ok, upstreamStatus: response.status,
      message: ok ? '网页 → 中转 → 坚果云连接及认证成功。尚未验证文件读写或自动同步。' : (messages[response.status] || '坚果云返回非预期状态，请稍后重试或检查服务。'),
    });
  } catch {
    return json(502, { ok: false, message: '中转连接坚果云失败或超时，请稍后重试。' });
  }
}

export default { fetch: handleRequestWrapper };
function handleRequestWrapper(request, env) { return handleRequest(request, env); }
