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
let token = sanitizeToken(params.get('t')) || localStorage.getItem('sp_token') || '';
if (params.get('t')) { localStorage.setItem('sp_token', token); history.replaceState(null, '', location.pathname); }
function msg(t) { const m = document.getElementById('msg'); m.textContent = t; setTimeout(() => m.textContent = '', 2500); }
function sanitizeToken(v) {
  // Strip whitespace and zero-width characters that sneak in via copy/paste.
  return (v || '').replace(/\s+/g, '').replace(/[\u200b\u200c\u200d\ufeff]/g, '');
}
async function api(path, opts) {
  const merged = Object.assign({ headers: {} }, opts);
  merged.headers = Object.assign({ 'X-SkyPaste-Token': token }, merged.headers || {});
  return fetch(path, merged);
