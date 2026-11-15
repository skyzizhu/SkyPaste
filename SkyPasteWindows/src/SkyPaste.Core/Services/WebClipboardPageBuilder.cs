using System.Text;

namespace SkyPaste.Core.Services;

/// <summary>
/// Builds the self-contained web clipboard page served by the LAN sync HTTP
/// service (GET /). Phones open it via the pairing QR/URL — no app install.
/// Token arrives via ?t= and is persisted in localStorage; the page shell
/// itself contains no secrets. Identical content to the macOS implementation.
/// </summary>
public static class WebClipboardPageBuilder
{
    public static string Build(string deviceName)
    {
        var sb = new StringBuilder(8 * 1024);
        sb.Append("""
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SkyPaste • 
""");
        sb.Append(Escape(deviceName));
        sb.Append("""
</title>
<style>
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
body { font-family: -apple-system, "PingFang SC", "Segoe UI", sans-serif; margin: 0; background: #f5f6fa; color: #141414; }
header { background: linear-gradient(135deg, #146bf0aa, #146bf022); padding: 18px 16px; }
header h1 { margin: 0; font-size: 18px; }
header p { margin: 4px 0 0; font-size: 12px; opacity: .75; }
main { padding: 14px; max-width: 560px; margin: 0 auto; }
section { background: #fff; border-radius: 14px; padding: 14px; margin-bottom: 14px; box-shadow: 0 1px 4px #0001; }
textarea { width: 100%; min-height: 96px; border: 1px solid #d8dbe4; border-radius: 10px; padding: 10px; font-size: 15px; resize: vertical; }
button { background: #146bf0; color: #fff; border: 0; border-radius: 20px; padding: 10px 18px; font-size: 15px; font-weight: 600; }
button.ghost { background: #eef2fb; color: #146bf0; }
.row { display: flex; gap: 10px; margin-top: 10px; }
.row button { flex: 1; }
ul { list-style: none; margin: 0; padding: 0; }
li { display: flex; align-items: center; gap: 8px; padding: 9px 0; border-bottom: 1px solid #f0f1f5; }
li span { flex: 1; font-size: 14px; word-break: break-all; }
li button { padding: 6px 14px; font-size: 13px; }
.empty { color: #8a8a8e; font-size: 13px; text-align: center; padding: 14px 0; }
#msg { text-align: center; font-size: 13px; color: #1f9e8c; min-height: 18px; margin: 0 0 8px; }
</style>
</head>
<body>
<header><h1>SkyPaste • 
""");
        sb.Append(Escape(deviceName));
        sb.Append("""
</h1><p>局域网直传 · 数据不出内网 · LAN direct, no cloud</p></header>
<main>
<p id="msg"></p>
<section id="tokenBox" style="display:none">
<p><b>首次使用 / First visit</b></p>
<p style="font-size:13px;color:#8a8a8e">令牌无效。请重新扫描电脑端设置里的二维码打开本页（推荐，无需输入）；或在下方输入电脑端显示的配对令牌。Token invalid — re-scan the QR in desktop Preferences (recommended), or enter the token below.</p>
<input id="tokenInput" style="width:100%;padding:10px;border:1px solid #d8dbe4;border-radius:10px;font-size:15px" placeholder="Pairing token">
<div class="row"><button onclick="saveToken()">保存 Save</button></div>
</section>

<section>
<p><b>发送到这台电脑 Send to this computer</b></p>
<textarea id="text" placeholder="粘贴或输入内容…"></textarea>
<div class="row">
<button class="ghost" onclick="readClip()">读取手机剪贴板</button>
<button onclick="sendText()">发送</button>
</div>
</section>
<section>
<p><b>电脑端最近内容 Recent from this computer</b> <button class="ghost" style="padding:6px 14px;font-size:13px;float:right" onclick="pull()">刷新</button></p>
<ul id="list"></ul>
<div class="empty" id="empty">暂无内容</div>
</section>
<script>
const params = new URLSearchParams(location.search);
let token = params.get('t') || localStorage.getItem('sp_token') || '';
if (params.get('t')) { localStorage.setItem('sp_token', token); history.replaceState(null, '', location.pathname); }
function msg(t) { const m = document.getElementById('msg'); m.textContent = t; setTimeout(() => m.textContent = '', 2500); }
function showTokenBox(prefill) {
  document.getElementById('tokenInput').value = prefill || '';
  document.getElementById('tokenBox').style.display = 'block';
}
function sanitizeToken(v) {
  // Strip whitespace and zero-width characters that sneak in via copy/paste.
  return (v || '').replace(/\s+/g, '').replace(/[\u200b\u200c\u200d\ufeff]/g, '');
}
function saveToken() {
  token = sanitizeToken(document.getElementById('tokenInput').value);
  if (!token) return;
  localStorage.setItem('sp_token', token);
  document.getElementById('tokenBox').style.display = 'none';
  pull();
}
async function api(path, opts) {
  const r = await fetch(path, Object.assign({ headers: { 'X-SkyPaste-Token': token } }, opts));
  if (r.status === 401) {
    // Keep the stored token for reference; rescan is the zero-typing path.
    showTokenBox(token);
    throw new Error('unauthorized');
  }
  return r;
}
async function readClip() {
  try { document.getElementById('text').value = await navigator.clipboard.readText(); }
  catch (e) { msg('read blocked, paste manually'); }
}
async function sendText() {
  const boxToken = sanitizeToken(document.getElementById('tokenInput').value);
  if (boxToken && boxToken !== token) { token = boxToken; localStorage.setItem('sp_token', token); }
  const text = document.getElementById('text').value;
  if (!text.trim()) { msg('empty'); return; }
  let r;
  try { r = await api('/paste', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text: text, device: '手机网页' }) }); }
  catch (e) { msg('token required'); return; }
  if (r.ok) { msg('✓ sent'); document.getElementById('text').value = ''; pull(); }
  else msg('failed ' + r.status);
}
async function copyItem(text) {
  try { await navigator.clipboard.writeText(text); msg('✓ copied'); }
  catch (e) { msg('copy blocked'); }
}
async function pull() {
  const boxToken = sanitizeToken(document.getElementById('tokenInput').value);
  if (boxToken && boxToken !== token) { token = boxToken; localStorage.setItem('sp_token', token); }
  let r;
  try { r = await api('/pull?since=0'); }
  catch (e) { return; }
  if (!r.ok) return;
  const items = await r.json();
  const list = document.getElementById('list');
  list.innerHTML = '';
  document.getElementById('empty').style.display = items.length ? 'none' : 'block';
  items.slice(0, 20).forEach(it => {
    const li = document.createElement('li');
    const s = document.createElement('span');
    s.textContent = it.text.length > 120 ? it.text.slice(0, 120) + '…' : it.text;
    const b = document.createElement('button');
    b.className = 'ghost'; b.textContent = '复制';
    b.onclick = () => copyItem(it.text);
    li.appendChild(s); li.appendChild(b); list.appendChild(li);
  });
}
pull();
</script>
</body>
</html>
""");
        return sb.ToString();
    }

    /// <summary>Escapes text interpolated into HTML contexts (title/header).</summary>
    private static string Escape(string value) =>
        value
            .Replace("&", "&amp;")
            .Replace("<", "&lt;")
            .Replace(">", "&gt;")
            .Replace("\"", "&quot;");
}
