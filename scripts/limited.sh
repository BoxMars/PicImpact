#!/usr/bin/env bash
#
# 带硬超时的命令包装。存在的原因：这个项目里有两类会静默挂住的命令 ——
#   1. 无头 Chrome：跑完 --dump-dom/--screenshot 后**不会退出**，反复调用会不断累积
#   2. SwiftPM：卡住的 swift test 会占住 .build/.lock，之后每个 swift 命令都静默等锁
# 两者都表现为「命令卡住」，而且不会自己报错。所以统一走这里：
#   - 先清理已知残留（无头 Chrome、测试进程、无人持有的构建锁）
#   - 再用 perl 的 alarm 做**硬超时**（macOS 没有 GNU timeout）
#   - 超时后明确打印 TIMEOUT 并以 124 退出，绝不静默返回 0
#
# 用法：scripts/limited.sh <秒> <命令...>
set -uo pipefail

LIMIT="${1:?用法: limited.sh <秒> <命令...>}"
shift

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- 1) 清理残留 ---
# 无头 Chrome 从不自己退出，直接杀；不影响用户手动开的 Chrome（不带 --headless）
pkill -f -- "--headless" 2>/dev/null
pkill -9 -f "PicImpactKitPackageTests" 2>/dev/null
pkill -9 -f "swiftpm-testing-helper" 2>/dev/null
# 只有在**没有** swift 进程时才清锁，避免误删正在进行的构建
if ! pgrep -qf "swift-build|swift-test|swift-frontend|swiftpm-testing" 2>/dev/null; then
  rm -f "$ROOT/ios/PicImpactKit/.build/.lock" 2>/dev/null
fi

# --- 2) 硬超时执行 ---
perl -e 'alarm shift; exec @ARGV' "$LIMIT" "$@"
CODE=$?
if [ "$CODE" -eq 142 ] || [ "$CODE" -eq 124 ]; then
  echo ""
  echo "  ⏱ TIMEOUT：超过 ${LIMIT}s 被强制终止（这就是之前"卡住"的表现）"
  exit 124
fi
exit "$CODE"
