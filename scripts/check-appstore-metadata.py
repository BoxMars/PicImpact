#!/usr/bin/env python3
"""校验 docs/appstore/metadata.md 里的字段长度是否超过 App Store Connect 上限。"""
import pathlib, re, sys

# App Store Connect 的硬性上限（超了会被直接拒绝）
LIMITS = {
    "名称": 30,
    "副标题": 30,
    "推广文本": 170,
    "描述": 4000,
    "关键词": 100,
}

text = pathlib.Path("docs/appstore/metadata.md").read_text()

def block_after(heading: str) -> str:
    """取某个标题后的第一个 ``` 代码块内容"""
    i = text.find(heading)
    assert i >= 0, f"找不到标题：{heading}"
    m = re.search(r"```\n(.*?)```", text[i:], re.S)
    assert m, f"标题 {heading} 后没有代码块"
    return m.group(1).strip()

def inline_value(label: str) -> str:
    m = re.search(rf"\*\*{label}\*\* \| ([^|]+)\|", text)
    assert m, f"找不到字段：{label}"
    return m.group(1).strip()

fields = {
    "名称": inline_value("名称"),
    "副标题": inline_value("副标题"),
    "推广文本": block_after("## 2. 推广文本"),
    "描述": block_after("## 3. 描述"),
    "关键词": block_after("## 4. 关键词"),
}

ok = True
print("  App Store Connect 字段长度校验：")
for name, value in fields.items():
    limit = LIMITS[name]
    n = len(value)
    good = n <= limit
    ok &= good
    print(f"    {'✓' if good else '✗'} {name:6s} {n:5d} / {limit:<5d} 字符")

# 关键词额外检查：不能有空格（空格占字符额度）
kw = fields["关键词"]
if " " in kw:
    print("    ✗ 关键词里出现了空格 —— 空格也占字符额度")
    ok = False
else:
    print("    ✓ 关键词无空格")

print("  结论:", "✓ 全部符合上限" if ok else "✗ 有字段超限")
sys.exit(0 if ok else 1)
