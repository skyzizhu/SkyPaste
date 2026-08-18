#!/usr/bin/env python3
"""build.py —— 把 content/ 编译为 site/js/data.js，使站点支持 file:// 直接双击打开。

- content/ 是唯一事实源：manifest.json + markdown/mermaid 文本
- data.js 是生成物：以全局变量 window.__PS_DATA 提供给站点（经典脚本，无 fetch/模块）
- 修改 content/ 后重新运行：python3 build.py
"""

import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent
CONTENT = ROOT / "content"
OUT = ROOT / "site" / "js" / "data.js"

manifest = json.loads((CONTENT / "manifest.json").read_text(encoding="utf-8"))

files = {}
for mod in manifest.get("modules", []):
    for page in mod.get("pages", []):
        f = page.get("file")
        if not f:
            continue
        if page.get("type") not in ("markdown", "mermaid"):
            continue  # 原型 / 信息图为独立 HTML，由 iframe 直接引用文件
        p = CONTENT / f
        if p.exists():
            files[f] = p.read_text(encoding="utf-8")

data = {"manifest": manifest, "files": files}
# 防止内容中出现 </script> 截断脚本标签：JSON 中 / 可安全转义为 \/
body = json.dumps(data, ensure_ascii=False, indent=2).replace("</", "<\\/")

js = (
    "// 本文件由 build.py 自动生成，请勿手改。\n"
    "// 更新 content/ 后重新运行：python3 build.py\n"
    "window.__PS_DATA = " + body + ";\n"
)

OUT.write_text(js, encoding="utf-8")
print(f"已生成 {OUT.relative_to(ROOT)}（manifest + {len(files)} 个文本内容文件）")
