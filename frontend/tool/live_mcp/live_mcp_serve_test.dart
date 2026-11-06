// Dev only: serves EveryAI's host MCP tools (now: browser) on loopback with a token, plus a small demo web app, so
// an outside agent can be pointed at them and review them. Not part of `flutter test` (it lives outside test/).
//
//   EVERYAI_LIVE_MCP_OUT=/path/live.json flutter test tool/live_mcp/live_mcp_serve_test.dart
//
// writes {"url", "token", "demo"} to that file and serves until a file named <out>.stop appears (or 40 min pass).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart';
import 'package:every_ai/features/code/harness/everyai/scrub.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Tools implements HostTools {
  _Tools(this.browser, this.root);
  final HeadlessBrowser browser;
  final String root;
  Future<void> _turn = Future.value();

  @override
  Future<HostResult> call(HostCall call) {
    final done = _turn.then((_) async {
      if (call.name != 'browser') return (text: 'Error: only browser is served here.', isError: true);
      final r = await runBrowser(
        browser,
        call.args,
        root: root,
        vision: true,
        fit: (t, _) => t.length > 30000 ? '${t.substring(0, 30000)}\n[… cut]' : t,
        scrub: Scrubber.forProject(root).redact,
      );
      for (final i in r.images) {
        final m = RegExp(r'^data:([^;]+);base64,(.*)$').firstMatch(i.dataUrl);
        if (m != null) call.images.add((mime: m[1]!, data: m[2]!));
      }
      return (text: r.text, isError: r.isError);
    });
    _turn = done.then((_) {}, onError: (Object _) {});
    return done;
  }
}

const _demo = '''<!doctype html><html><head><title>Tea Shop</title><style>
body{font-family:sans-serif;margin:24px;max-width:900px} .item{display:flex;gap:12px;align-items:center;margin:6px 0}
#cart{position:fixed;right:24px;top:24px;background:#eef;padding:8px 12px;border-radius:8px}
.tiny{font-size:9px;color:#888} canvas{border:1px solid #ccc}</style></head><body>
<h1>Tea Shop</h1><div id=cart>Cart: <b id=count>0</b></div>
<label>Search <input id=q placeholder="green, black…"></label> <button id=go>Search</button>
<p id=status></p>
<h2>Teas</h2><div id=list></div>
<h2>Sign in</h2><form id=login onsubmit="event.preventDefault();status.textContent='signed in as '+email.value">
<input id=email type=email aria-label="Email"> <input id=pw type=password aria-label="Password">
<button type=submit>Sign in</button></form>
<h2>Drawing</h2><canvas id=c width=300 height=120></canvas>
<p class=tiny>Small print: <a href="#terms" onclick="status.textContent='terms opened'">terms</a></p>
<div style="height:1400px"></div><button id=bottom onclick="status.textContent='bottom reached'">Bottom button</button>
<script>
const teas=['Sencha','Assam','Oolong','Earl Grey','Rooibos'];
let n=0; const list=document.getElementById('list');
function render(f){list.innerHTML='';teas.filter(t=>t.toLowerCase().includes(f.toLowerCase())).forEach(t=>{
 const d=document.createElement('div');d.className='item';d.innerHTML='<span>'+t+'</span>';
 const b=document.createElement('button');b.textContent='Add '+t;b.onclick=()=>{count.textContent=++n;console.log('added',t)};
 d.appendChild(b);list.appendChild(d);});}
render('');go.onclick=()=>{render(q.value);status.textContent='results for '+q.value};
const x=c.getContext('2d');x.fillStyle='#c33';x.fillRect(20,20,80,80);x.fillStyle='#3a3';x.beginPath();x.arc(200,60,40,0,7);x.fill();
c.onclick=e=>{status.textContent='canvas clicked at '+e.offsetX+','+e.offsetY};
document.cookie='session=dev-secret-cookie';localStorage.setItem('token','dev-local-token');
setTimeout(()=>{throw new Error('demo: a late error')},1500);
</script></body></html>''';

void main() {
  final out = Platform.environment['EVERYAI_LIVE_MCP_OUT'];
  test('serve the host browser tool', () async {
    if (out == null) return;
    final tmp = Directory.systemTemp.createTempSync('live-mcp');
    final app = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    app.listen((req) {
      req.response
        ..headers.contentType = ContentType.html
        ..write(_demo);
      unawaited(req.response.close());
    });
    final browser = HeadlessBrowser(profileDir: '${tmp.path}/profile');
    final server = createHostServer(
      idleLimit: const Duration(hours: 1),
      heldLimit: const Duration(minutes: 5),
      keepAlive: const Duration(seconds: 15),
    );
    final token = await server.mint('live-mcp', _Tools(browser, tmp.path), only: {'browser'});
    File(out).writeAsStringSync(
      jsonEncode({'url': '${token.url}', 'token': token.token, 'demo': 'http://127.0.0.1:${app.port}/'}),
    );
    final end = DateTime.now().add(const Duration(minutes: 40));
    while (!File('$out.stop').existsSync() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await server.stop();
    await browser.close();
    await browser.host.stop();
    await app.close(force: true);
    tmp.deleteSync(recursive: true);
  }, timeout: Timeout.none);
}
