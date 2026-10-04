#!/usr/bin/env bash
# 跑 PicImpactKit 单元测试。
#
# ⚠️ 为什么不直接用 `swift test 2>&1 | grep ...`：
# 管道的退出码默认来自**最后一个命令**（grep），所以测试失败也会返回 0 ——
# 本仓库真的发生过：测试挂了一个，命令却"成功"退出，结果带着失败提交并推送了。
# 这里用 `set -o pipefail` 让管道整体返回非零，并把结论打印清楚。
set -euo pipefail

cd "$(dirname "$0")/../ios/PicImpactKit"
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

if swift test > "$OUT" 2>&1; then
    grep -E "Test run with" "$OUT" | tail -1
    exit 0
else
    echo "❌ 测试失败：" >&2
    # 不用 `grep | head`：head 提前关闭管道会让脚本以 SIGPIPE(141) 退出，
    # 掩盖掉本意的退出码 1（这个坑真踩过）。改为先取再打印。
    grep -E "✘|Expectation failed|error:|Test run with" "$OUT" > "$OUT.summary" || true
    awk 'NR <= 20' "$OUT.summary" >&2
    exit 1
fi
