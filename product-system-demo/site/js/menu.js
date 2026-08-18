// menu.js —— 左侧菜单树的构建与选中状态

var PS = window.PS || {};

var COLLAPSE_KEY = "ps.menu.collapsed";

function loadCollapsed() {
  try { return JSON.parse(localStorage.getItem(COLLAPSE_KEY) || "{}"); }
  catch (e) { return {}; }
}

function saveCollapsed() {
  // 记录用户对所有分组的显式选择：true=折叠，false=展开
  var state = {};
  document.querySelectorAll(".menu-group").forEach(function (g) {
    state[g.dataset.module] = g.classList.contains("collapsed");
  });
  try { localStorage.setItem(COLLAPSE_KEY, JSON.stringify(state)); } catch (e) { /* 忽略 */ }
}

PS.buildMenu = function (manifest) {
  var nav = document.getElementById("menu");
  var frag = document.createDocumentFragment();
  var collapsed = loadCollapsed();

  manifest.modules.forEach(function (mod) {
    var group = document.createElement("div");
    group.className = "menu-group";
    group.dataset.module = mod.id;

    if (mod.special === "pending-report") {
      var a = document.createElement("a");
      a.className = "menu-item";
      a.href = "#/" + mod.id + "/report";
      a.dataset.module = mod.id;
      a.dataset.page = "report";
      a.innerHTML =
        '<span class="title">⏳ ' + PS.escapeHtml(mod.title) + "</span>" +
        '<span class="menu-count" data-pending-count>0</span>';
      group.appendChild(a);
      frag.appendChild(group);
      return;
    }

    var title = document.createElement("h3");
    title.className = "menu-title";
    title.textContent = mod.title;
    var arrow = document.createElement("span");
    arrow.className = "menu-arrow";
    arrow.textContent = "▾";
    title.appendChild(arrow);
    // 点击一级菜单：折叠 / 展开二级菜单
    title.addEventListener("click", function () {
      group.classList.toggle("collapsed");
      saveCollapsed();
    });
    group.appendChild(title);

    if (Object.prototype.hasOwnProperty.call(collapsed, mod.id)) {
      // 用户做过显式选择，尊重其选择
      if (collapsed[mod.id]) group.classList.add("collapsed");
    } else {
      // 默认折叠
      group.classList.add("collapsed");
    }

    mod.pages.forEach(function (page) {
      var item = document.createElement("a");
      item.className = "menu-item";
      item.href = "#/" + mod.id + "/" + page.id;
      item.dataset.module = mod.id;
      item.dataset.page = page.id;
      item.title = page.status === "confirmed" ? "已确认" : "待确认";
      item.innerHTML =
        '<span class="dot ' + (page.status === "confirmed" ? "dot-ok" : "dot-pending") + '"></span>' +
        '<span class="title">' + PS.escapeHtml(page.title) + "</span>" +
        (page.source === "ai-inferred" ? '<i class="ai-chip">AI</i>' : "");
      group.appendChild(item);
    });

    frag.appendChild(group);
  });

  nav.innerHTML = "";
  nav.appendChild(frag);
};

PS.setActive = function (moduleId, pageId) {
  document.querySelectorAll(".menu-item").forEach(function (el) {
    el.classList.toggle("active", el.dataset.module === moduleId && el.dataset.page === pageId);
  });
  // 当前路由所在分组自动展开（临时态，不写入记忆），避免全折叠后看不到位置
  var group = document.querySelector('.menu-group[data-module="' + moduleId + '"]');
  if (group && group.classList.contains("collapsed")) group.classList.remove("collapsed");
};

PS.setPendingCount = function (n) {
  var el = document.querySelector("[data-pending-count]");
  if (el) el.textContent = String(n);
};

window.PS = PS;
