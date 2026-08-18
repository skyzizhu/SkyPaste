# 产品系统 Demo

输入 PRD / 零散产品需求 → 输出可浏览的「产品系统」Web 站点。

## 架构：内容与站点分离

```
product-system-demo/
├── build.py                  # 构建脚本：content/ → site/js/data.js
├── content/                  # 纯内容层（skill 每次生成/更新的部分）
│   ├── manifest.json         # 结构唯一事实源：模块、页面、溯源状态
│   ├── overview/             # 产品概览
│   ├── requirements/         # 需求文档（.md）+ 流程/泳道/状态图（.mmd）
│   ├── info-structure/       # 信息结构图（HTML/CSS 卡片）
│   ├── prototype/            # 低保真线框原型（共享 assets/wireframe.css）
│   ├── testing/              # 验收标准、测试用例
│   └── launch/               # 上线目标、checklist
└── site/                     # 展示外壳（写好后基本不动）
    ├── index.html            # 唯一入口：菜单容器 + 内容区骨架
    ├── css/                  # base / layout / content 三层拆分
    └── js/                   # data(生成) + loader / router / menu / render / main
```

## 运行

**双击 `site/index.html` 即可直接浏览**（file:// 兼容，无需本地服务）。

原理：站点不使用 fetch 与 ES modules（二者会被 file:// 的 CORS 策略拦截），
而是由 `build.py` 把 content/ 编译成 `site/js/data.js` 全局数据，JS 全部为按序加载的经典脚本。

修改 content/ 后重新编译：

```bash
python3 build.py
```

如仍偏好 HTTP 访问（可选，两种方式随时切换）：

```bash
cd product-system-demo
python3 -m http.server 4173
# 打开 http://localhost:4173/site/
```

## 溯源约定

manifest 中每个页面携带两个标记，菜单与页面头部均以徽标呈现：

- `source`: `origin`（PRD 原文）/ `ai-inferred`（AI 推断补全）
- `status`: `confirmed`（已确认）/ `pending`（待确认）

左侧第一个菜单「待确认清单」聚合所有 pending 项，供评审逐条确认。
