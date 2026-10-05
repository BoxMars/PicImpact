#!/usr/bin/env python3
"""打包种子（seed）：把站点当前的**全部 JSON 元数据**与**首页照片的预览图**抓下来，
放进 App 资源里，这样用户**第一次启动、还没联网**就能看到内容。

用法：
    python3 scripts/ios-seed.py            # 抓取并写入 ios/FelinaGallery/Resources/Seed/
    python3 scripts/ios-seed.py --check    # 只校验已生成的内容是否完整

产物：
    ios/FelinaGallery/Resources/Seed/seed.json     站点配置 + 全部页的 JSON + 图片清单
    ios/FelinaGallery/Resources/Seed/images/*.webp 首页那 24 张预览图

设计要点：
  * **只抓预览图，不抓原图**。原图平均 3.4 MB/张，首页 24 张就 83 MB，
    而详情页才按原图宽度显示、卡片只有屏宽 1/3，把原图打进包里几乎看不到收益。
  * manifest 里记的是 **previewUrl → 文件名** 的对应关系；App 侧用自己的
    ImageCache.store(_:for:) 把文件写进缓存，**不在脚本里复刻缓存键** ——
    两边各算一套哈希迟早对不上，缓存就永远命中不了。
  * 站点的公开 API 前面是 Cloudflare，会拦掉 python 默认 UA（403），所以这里统一用 curl。
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import time

BASE = "https://felina.boxz.dev/api/public/v1"
ROOT = pathlib.Path(__file__).resolve().parent.parent
SEED = ROOT / "ios/FelinaGallery/Resources/Seed"
IMAGES = SEED / "images"
UA = "FelinaGallery-SeedBuilder/1.0"


def curl_bytes(url: str) -> bytes:
    out = subprocess.run(
        ["curl", "-sS", "--max-time", "120", "-A", UA, url],
        capture_output=True,
    )
    if out.returncode != 0 or not out.stdout:
        raise RuntimeError(f"抓取失败 {url}: {out.stderr.decode()[:200]}")
    return out.stdout


def curl_json(url: str) -> dict:
    return json.loads(curl_bytes(url))


def curl_to_file(url: str, dest: pathlib.Path) -> int:
    out = subprocess.run(
        ["curl", "-sS", "--max-time", "120", "-A", UA, "-o", str(dest), "-w", "%{http_code}", url],
        capture_output=True, text=True,
    )
    code = out.stdout.strip()
    if out.returncode != 0 or code != "200":
        raise RuntimeError(f"下载失败 {url}: HTTP {code} {out.stderr[:200]}")
    return dest.stat().st_size


def build() -> None:
    print("  抓取站点配置…")
    config = curl_json(f"{BASE}/config")
    print("  抓取全部图片元数据…")
    pages, page = [], 1
    while True:
        body = curl_json(f"{BASE}/images?page={page}")
        pages.append(body)
        data = body.get("data", {})
        total = data.get("pageTotal", 1)
        print(f"    第 {page}/{total} 页，{len(data.get('list', []))} 张")
        if not data.get("hasMore") or page >= total:
            break
        page += 1

    first = (pages[0].get("data", {}).get("list") or [])
    IMAGES.mkdir(parents=True, exist_ok=True)
    for old in IMAGES.glob("*.webp"):
        old.unlink()
    manifest, total_bytes = {}, 0
    print(f"  下载首页 {len(first)} 张预览图…")
    for i, item in enumerate(first):
        url = item.get("previewUrl")
        if not url:
            continue
        name = f"{i:02d}.webp"
        size = curl_to_file(url, IMAGES / name)
        manifest[url] = name
        total_bytes += size
        print(f"    [{i + 1:2d}/{len(first)}] {size / 1024:5.0f} KB  {name}")

    seed = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "source": BASE,
        "config": config,
        "pages": pages,
        # previewUrl → 资源里的文件名
        "imageFiles": manifest,
    }
    SEED.mkdir(parents=True, exist_ok=True)
    (SEED / "seed.json").write_text(json.dumps(seed, ensure_ascii=False, indent=2))
    json_kb = (SEED / "seed.json").stat().st_size / 1024
    print(f"\n  ✓ seed.json {json_kb:.0f} KB（配置 + {len(pages)} 页元数据）")
    print(f"  ✓ 预览图 {len(manifest)} 张，合计 {total_bytes / 1024 / 1024:.2f} MB")


def check() -> int:
    seed_path = SEED / "seed.json"
    if not seed_path.exists():
        print("  ✗ 还没有 seed.json，先跑一次 scripts/ios-seed.py")
        return 1
    seed = json.loads(seed_path.read_text())
    manifest = seed.get("imageFiles", {})
    pages = seed.get("pages", [])
    first = (pages[0].get("data", {}).get("list") or []) if pages else []
    missing = [u for u in manifest if not (IMAGES / manifest[u]).exists()]
    problems = []
    if not pages:
        problems.append("pages 为空")
    if len(manifest) != len(first):
        problems.append(f"清单 {len(manifest)} 条 ≠ 首页 {len(first)} 张")
    if missing:
        problems.append(f"{len(missing)} 个清单文件不存在")
    total = sum((IMAGES / f).stat().st_size for f in manifest.values() if (IMAGES / f).exists())
    print(f"  生成时间: {seed.get('generatedAt')}")
    print(f"  元数据: {len(pages)} 页 / {sum(len(p.get('data', {}).get('list', [])) for p in pages)} 张")
    print(f"  预览图: {len(manifest)} 张 / {total / 1024 / 1024:.2f} MB")
    for p in problems:
        print(f"  ✗ {p}")
    print("  ✓ 校验通过" if not problems else "  ✗ 校验失败")
    return 0 if not problems else 1


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(check())
    build()
