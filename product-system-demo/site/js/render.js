// render.js —— 渲染层：markdown 解析、Mermaid、徽标、待确认清单

var PS = window.PS || {};

PS.escapeHtml = function (s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
};

function inline(s) {
  return PS.escapeHtml(s)
    // 图片：![alt](src)。src 为 content 相对路径时自动加 ../content/ 前缀，http(s) 原样
    .replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, function (m, alt, src) {
      var url = /^https?:/i.test(src) ? src : "../content/" + src.replace(/^\.\.\/content\//, "").replace(/^\/+/, "");
      return '<img src="' + url + '" alt="' + alt + '">';
    })
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
}

function renderList(items) {
  var root = { text: "", children: [] };
  var lastTop = root;
  items.forEach(function (it) {
    var node = { text: it.text, children: [] };
    if (it.indent < 2) {
      root.children.push(node);
      lastTop = node;
    } else {
      lastTop.children.push(node);
    }
  });
  var tag = items[0].ordered ? "ol" : "ul";
  function liHtml(n) {
    var m = n.text.match(/^\[( |x|X)\]\s*(.*)$/);
    if (m) {
      var done = m[1].toLowerCase() === "x";
      var body = '<span class="cb">' + (done ? "☑" : "☐") + "</span> " + inline(m[2]);
      var kids = n.children.length ? "<ul>" + n.children.map(liHtml).join("") + "</ul>" : "";
      return '<li class="task' + (done ? " done" : "") + '">' + body + kids + "</li>";
    }
    var kids2 = n.children.length ? "<ul>" + n.children.map(liHtml).join("") + "</ul>" : "";
    return "<li>" + inline(n.text) + kids2 + "</li>";
  }
  return "<" + tag + ">" + root.children.map(liHtml).join("") + "</" + tag + ">";
}

PS.mdToHtml = function (md) {
  var lines = String(md).replace(/\r\n?/g, "\n").split("\n");
  var out = [];
  var i = 0;

  while (i < lines.length) {
    var line = lines[i];

    // 代码块 / mermaid 块
    if (/^```/.test(line)) {
      var lang = line.slice(3).trim().toLowerCase();
      i++;
      var buf = [];
      while (i < lines.length && !/^```/.test(lines[i])) buf.push(lines[i++]);
      i++;
      if (lang === "mermaid") {
        out.push('<div class="mermaid-inline">' + PS.escapeHtml(buf.join("\n")) + "</div>");
      } else {
        out.push('<pre class="code"><code>' + PS.escapeHtml(buf.join("\n")) + "</code></pre>");
      }
      continue;
    }

    if (/^\s*$/.test(line)) { i++; continue; }

    if (/^(-{3,}|\*{3,})\s*$/.test(line)) { out.push("<hr>"); i++; continue; }

    // 标题
    var m = line.match(/^(#{1,4})\s+(.*)$/);
    if (m) {
      var level = m[1].length;
      out.push("<h" + level + ">" + inline(m[2]) + "</h" + level + ">");
      i++;
      continue;
    }

    // 表格
    if (/^\s*\|/.test(line)) {
      var rows = [];
      while (i < lines.length && /^\s*\|/.test(lines[i])) rows.push(lines[i++]);
      function cells(r) {
        return r.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map(function (c) { return c.trim(); });
      }
      var head = cells(rows[0]);
      var body = rows.slice(1)
        .filter(function (r) { return !/^[\s|:-]+$/.test(r); })
        .map(cells);
      out.push(
        "<table><thead><tr>" +
        head.map(function (c) { return "<th>" + inline(c) + "</th>"; }).join("") +
        "</tr></thead><tbody>" +
        body.map(function (r) {
          return "<tr>" + r.map(function (c) { return "<td>" + inline(c) + "</td>"; }).join("") + "</tr>";
        }).join("") +
        "</tbody></table>"
      );
      continue;
    }

    // 列表（支持一级嵌套）
    m = line.match(/^(\s*)([-*]|\d+\.)\s+(.*)$/);
    if (m) {
      var items = [];
      while (i < lines.length && (m = lines[i].match(/^(\s*)([-*]|\d+\.)\s+(.*)$/))) {
        items.push({ indent: m[1].length, ordered: /\d/.test(m[2]), text: m[3] });
        i++;
      }
      out.push(renderList(items));
      continue;
    }

    // 引用块（用作待确认 / AI 推断提示）
    if (/^\s*>/.test(line)) {
      var qbuf = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) {
        qbuf.push(lines[i++].replace(/^\s*>\s?/, ""));
      }
      out.push("<blockquote>" + qbuf.map(inline).join("<br>") + "</blockquote>");
      continue;
    }

    // 段落
    var pbuf = [line];
    i++;
    while (i < lines.length && !/^\s*$/.test(lines[i]) &&
           !/^(#{1,4}\s|```|\s*>|\s*\||\s*([-*]|\d+\.)\s)/.test(lines[i])) {
      pbuf.push(lines[i++]);
    }
    out.push("<p>" + inline(pbuf.join(" ")) + "</p>");
  }

  return out.join("\n");
};

// Mermaid 渲染：CDN 脚本加载慢时最多等待 2.5s，超时降级为源码展示
PS.renderMermaid = async function (el, code) {
  var waited = 0;
  while (!window.mermaid && waited < 2500) {
    await new Promise(function (r) { setTimeout(r, 100); });
    waited += 100;
  }
  if (window.mermaid) {
    try {
      if (!PS.__mmdInit) {
        window.mermaid.initialize({ startOnLoad: false, theme: "neutral", securityLevel: "loose" });
        PS.__mmdInit = true;
      }
      var id = "mmd-" + Math.random().toString(36).slice(2, 9);
      var res = await window.mermaid.render(id, code);
      el.innerHTML = '<div class="mermaid-box">' + res.svg + "</div>";
      return;
    } catch (e) {
      // 渲染失败则降级
    }
  }
  el.innerHTML =
    '<div class="callout warn">⚠️ Mermaid 未能渲染（CDN 不可达或语法错误），已降级为源码展示。</div>' +
    '<pre class="code"><code>' + PS.escapeHtml(code) + "</code></pre>";
};

PS.badgesHtml = function (page) {
  var src = page.source === "ai-inferred"
    ? '<span class="badge badge-ai">AI 推断</span>'
    : '<span class="badge badge-origin">PRD 原文</span>';
  var st = page.status === "confirmed"
    ? '<span class="badge badge-ok">已确认</span>'
    : '<span class="badge badge-pending">待确认</span>';
  return src + st;
};

PS.pendingReportHtml = function (manifest) {
  var groups = [];
  manifest.modules
    .filter(function (m) { return !m.special; })
    .forEach(function (mod) {
      var pend = mod.pages.filter(function (p) { return p.status === "pending"; });
      if (pend.length) groups.push({ mod: mod, pend: pend });
    });
  var total = groups.reduce(function (s, g) { return s + g.pend.length; }, 0);

  var html =
    '<h1 class="page-title">⏳ 待确认清单</h1>' +
    '<p class="page-summary">共 ' + total + ' 项内容处于「待确认」状态。逐条评审后，在 manifest 中将 status 改为 confirmed，并重新运行 build.py。</p>';

  if (!total) return html + '<div class="callout ok">✅ 全部内容已确认。</div>';

  groups.forEach(function (g) {
    html += "<h2>" + PS.escapeHtml(g.mod.title) + '</h2><ul class="pending-list">' +
      g.pend.map(function (p) {
        var srcBadge = p.source === "ai-inferred"
          ? '<span class="badge badge-ai">AI 推断</span>'
          : '<span class="badge badge-origin">PRD 原文</span>';
        return '<li><a href="#/' + g.mod.id + "/" + p.id + '">' + PS.escapeHtml(p.title) + "</a>" + srcBadge +
          '<span class="badge badge-pending">待确认</span></li>';
      }).join("") +
      "</ul>";
  });
  return html;
};

window.PS = PS;
