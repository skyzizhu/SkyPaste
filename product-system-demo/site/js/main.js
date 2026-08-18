// main.js —— 入口：读取已编译数据 → 构建菜单 → 路由分发渲染

var PS = window.PS || {};

// 产品形态 → 展示标签（skill 流程要求：输入无法判断形态时必须询问用户）
var FORM_LABELS = {
  web: "Web 应用",
  desktop: "桌面客户端",
  mobile: "手机 App",
  h5: "H5（手机网页）",
  miniapp: "小程序",
  tv: "电视大屏端"
};

PS.boot = async function () {
  var manifest;
  try {
    manifest = PS.getManifest();
  } catch (e) {
    document.getElementById("brand-name").textContent = "产品系统";
    document.getElementById("content").innerHTML =
      '<div class="callout warn">⚠️ ' + PS.escapeHtml(e.message) + "</div>";
    return;
  }

  // 品牌区
  document.getElementById("brand-name").innerHTML =
    PS.escapeHtml(manifest.product.name) +
    ' <span class="brand-version">v' + PS.escapeHtml(manifest.product.version) + "</span>";
  var formLabel = FORM_LABELS[manifest.product.form] || "";
  document.getElementById("brand-meta").textContent =
    (formLabel ? formLabel + " · " : "") +
    manifest.product.tagline + " · 更新于 " + manifest.product.updated;

  PS.buildMenu(manifest);

  var pendingTotal = 0;
  manifest.modules.forEach(function (m) {
    m.pages.forEach(function (p) { if (p.status === "pending") pendingTotal++; });
  });
  PS.setPendingCount(pendingTotal);

  function findTarget(moduleId, pageId) {
    var mod = manifest.modules.filter(function (m) { return m.id === moduleId; })[0] ||
      manifest.modules.filter(function (m) { return m.pages.length; })[0] || manifest.modules[0];
    if (mod.special) {
      return { mod: mod, page: { id: "report", title: mod.title, type: "special", source: "origin", status: "confirmed" } };
    }
    var page = mod.pages.filter(function (p) { return p.id === pageId; })[0] || mod.pages[0];
    return { mod: mod, page: page };
  }

  function pageHeader(page) {
    var summary = page.summary
      ? '<p class="page-summary">' + PS.escapeHtml(page.summary) + "</p>"
      : "";
    return '<h1 class="page-title">' + PS.escapeHtml(page.title) + "</h1>" + summary;
  }

  async function renderContent(mod, page) {
    var content = document.getElementById("content");

    if (mod.special === "pending-report") {
      content.className = "content";
      content.innerHTML = '<div class="doc">' + PS.pendingReportHtml(manifest) + "</div>";
      return;
    }

    if (page.type === "markdown") {
      var text = PS.loadText(page.file);
      content.className = "content";
      content.innerHTML = '<div class="doc">' + pageHeader(page) + PS.mdToHtml(text) + "</div>";
      // markdown 内嵌的 mermaid 块
      var nodes = Array.prototype.slice.call(content.querySelectorAll(".mermaid-inline"));
      for (var k = 0; k < nodes.length; k++) {
        await PS.renderMermaid(nodes[k], nodes[k].textContent);
      }
      return;
    }

    if (page.type === "mermaid") {
      var code = PS.loadText(page.file);
      content.className = "content";
      content.innerHTML = '<div class="doc">' + pageHeader(page) + "</div>";
      var box = document.createElement("div");
      content.querySelector(".doc").appendChild(box);
      await PS.renderMermaid(box, code);
      return;
    }

    if (page.type === "prototype" || page.type === "html-embed") {
      var label = page.type === "prototype" ? "低保真线框原型" : "HTML 信息结构图";
      var url = PS.contentUrl(page.file);
      content.className = "content embed-mode";
      content.innerHTML =
        '<div class="embed-bar"><span>' + label + " · <code>" + PS.escapeHtml(page.file) + "</code></span>" +
        '<a href="' + url + '" target="_blank" rel="noopener">新窗口打开 ↗</a></div>' +
        '<iframe class="embed" src="' + url + '" title="' + PS.escapeHtml(page.title) + '"></iframe>';
      return;
    }

    content.className = "content";
    content.innerHTML = '<div class="callout warn">⚠️ 未知页面类型</div>';
  }

  async function route() {
    var parsed = PS.parseHash();
    var target = findTarget(parsed.moduleId, parsed.pageId);
    var mod = target.mod;
    var page = target.page;

    var want = "#/" + mod.id + "/" + page.id;
    if (location.hash !== want) {
      location.hash = want; // 规范化后由 hashchange 再触发
      return;
    }

    PS.setActive(mod.id, page.id);
    document.title = page.title + " · " + manifest.product.name + " 产品系统";
    document.getElementById("breadcrumb").innerHTML =
      "<span>" + PS.escapeHtml(manifest.product.name) + " 产品系统</span><span>/</span>" +
      "<span>" + PS.escapeHtml(mod.title) + "</span><span>/</span><b>" + PS.escapeHtml(page.title) + "</b>";
    document.getElementById("page-badges").innerHTML = mod.special ? "" : PS.badgesHtml(page);

    var content = document.getElementById("content");
    content.className = "content";
    content.innerHTML = '<p class="loading">加载中…</p>';
    try {
      await renderContent(mod, page);
    } catch (err) {
      content.innerHTML = '<div class="callout warn">⚠️ 加载失败：' + PS.escapeHtml(err.message) + "</div>";
    }
  }

  PS.initRouter(route);
  if (!location.hash) location.hash = "/overview/index";
  route();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", function () { PS.boot(); });
} else {
  PS.boot();
}
