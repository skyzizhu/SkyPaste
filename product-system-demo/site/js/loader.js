// loader.js —— 数据访问：从预编译的 data.js 全局数据读取（兼容 file:// 直开）

var PS = window.PS || {};

PS.data = function () {
  return window.__PS_DATA || { manifest: null, files: {} };
};

PS.getManifest = function () {
  var m = PS.data().manifest;
  if (!m) {
    throw new Error("data.js 未加载或内容为空，请先运行 python3 build.py 重新编译内容");
  }
  return m;
};

// 原型 / 信息图等独立 HTML 文件仍按相对路径引用（file:// 与 http:// 均适用）
PS.contentUrl = function (file) {
  return "../content/" + String(file).replace(/^\/+/, "");
};

PS.loadText = function (file) {
  var files = PS.data().files || {};
  if (!(file in files)) {
    throw new Error("内容未编译进 data.js: " + file + "（请运行 python3 build.py）");
  }
  return files[file];
};

window.PS = PS;
