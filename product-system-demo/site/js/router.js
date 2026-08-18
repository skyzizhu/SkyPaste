// router.js —— hash 路由：#/模块ID/页面ID

var PS = window.PS || {};

PS.parseHash = function () {
  var raw = decodeURIComponent(location.hash.replace(/^#\/?/, ""));
  var parts = raw.split("/");
  return { moduleId: parts[0] || "", pageId: parts[1] || "" };
};

PS.initRouter = function (handler) {
  window.addEventListener("hashchange", handler);
};

window.PS = PS;
