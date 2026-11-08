// get.everyai.dev: serves the install scripts and the Linux release key, and names the latest release.
// The packages themselves download from GitHub Releases (the scripts pin the version they looked up).
//
//   /                 curl/wget → install.sh, PowerShell → install.ps1, a browser → the README's install section
//   /install.sh       macOS and Linux
//   /install.ps1      Windows (Microsoft Store through winget)
//   /key.asc          the GPG key that signs the Linux SHA256SUMS
//   /icon-256.png, /icon.svg   the app icon (when the installer can't take it from the AppImage)
//   /latest/version   e.g. 0.1.0-alpha.6 (GitHub's latest release, cached 5 minutes)

const REPO = 'xuckless/everyai-mono';
const README = `https://github.com/${REPO}#-get-started`;
const FILES = new Set(['/install.sh', '/install.ps1', '/key.asc', '/icon-256.png', '/icon.svg']);

export default {
  async fetch(request, env) {
    if (request.method !== 'GET' && request.method !== 'HEAD') return new Response('method not allowed\n', { status: 405 });
    const url = new URL(request.url);
    let path = url.pathname;
    if (path === '/') {
      const agent = request.headers.get('user-agent') || '';
      if (/PowerShell/i.test(agent)) path = '/install.ps1';
      else if (/^(curl|Wget)\//i.test(agent)) path = '/install.sh';
      else return Response.redirect(README, 302);
    }
    if (path === '/latest/version') return latestVersion();
    if (FILES.has(path)) return text(await env.ASSETS.fetch(new Request(new URL(path, url.origin), request)));
    return new Response('not found\n', { status: 404 });
  },
};

async function latestVersion() {
  const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
    headers: { 'user-agent': 'everyai-get', accept: 'application/vnd.github+json' },
    cf: { cacheTtl: 300, cacheEverything: true },
  });
  if (!res.ok) return new Response(`GitHub answered ${res.status}\n`, { status: 502 });
  const tag = String((await res.json()).tag_name || '');
  if (!/^v?[0-9A-Za-z.+-]+$/.test(tag)) return new Response('no release\n', { status: 502 });
  return new Response(tag.replace(/^v/, '') + '\n', {
    headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=300' },
  });
}

function text(res) {
  const out = new Response(res.body, res);
  if (res.ok && !/\.(png|svg)$/.test(new URL(res.url || 'x:/').pathname)) {
    out.headers.set('content-type', 'text/plain; charset=utf-8');
    out.headers.set('cache-control', 'public, max-age=300');
  }
  out.headers.set('x-content-type-options', 'nosniff');
  return out;
}
