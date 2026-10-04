#!/usr/bin/env bash
#
# 审计"纸色底 + 描边 + 硬阴影"这个模式有没有被手写第二遍。
#
# 为什么需要它：这个模式原先在五个地方各写了一遍，其中三处把 `.shadow`
# 写在了 `.overlay { strokeBorder }` 之后 —— 描边内侧会多出一条阴影线，
# 控件看起来有两条边框（用户为此反馈过三次）。顺序只在
# `islandSurface` 里定义一次，这里守住"不能有第二处同时用到描边与硬阴影"。
set -uo pipefail

SRC="ios/PicImpactKit/Sources/PicImpactKit"
ALLOWED="DesignSystem/IslandControls.swift"
violations=0

while IFS= read -r file; do
  # 只看**非注释**行，避免把说明文字里的 strokeBorder 也算进来
  code=$(grep -v '^\s*//' "$file" | grep -v '^\s*///')
  has_stroke=$(printf '%s' "$code" | grep -c 'strokeBorder(' || true)
  has_shadow=$(printf '%s' "$code" | grep -c 'cardShadowHard' || true)
  if [ "$has_stroke" -gt 0 ] && [ "$has_shadow" -gt 0 ]; then
    rel="${file#"$SRC"/}"
    if [ "$rel" != "$ALLOWED" ]; then
      echo "  ✗ $rel 同时手写了描边与硬阴影 —— 请改用 islandSurface()"
      violations=$((violations + 1))
    fi
  fi
done < <(find "$SRC" -name '*.swift')

if [ "$violations" -gt 0 ]; then
  echo ""
  echo "  有 $violations 处绕过了统一实现。顺序写反会让控件出现两条边框。"
  exit 1
fi
echo "  ✓ 描边+硬阴影只出现在 $ALLOWED 一处"
