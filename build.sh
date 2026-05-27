#!/bin/bash
# ============================================================
# build.sh  —  Render 部署时自动执行：下载 KataGo + 围棋模型
# ============================================================
set -e

mkdir -p ./lib

# ── 方案1：直接从系统查找 libzip（最快，通常 Render Ubuntu 已有 .so.4）──
echo "▶ 查找系统中的 libzip..."
SYSTEM_LIBZIP=$(find /usr/lib /lib -name 'libzip.so*' 2>/dev/null | head -1)
if [ -n "$SYSTEM_LIBZIP" ]; then
    cp "$SYSTEM_LIBZIP" ./lib/libzip.so.5
    echo "✓ 从系统复制: $SYSTEM_LIBZIP → ./lib/libzip.so.5"
else
    echo "  系统未找到 libzip，继续下一步..."
fi

# ── 方案2：尝试 apt-get（某些 Render 环境有权限）──
if [ ! -f "./lib/libzip.so.5" ]; then
    echo "▶ 尝试 apt-get 安装 libzip..."
    if sudo apt-get install -y libzip5 libzip4 2>/dev/null || apt-get install -y libzip5 libzip4 2>/dev/null; then
        echo "✓ apt-get 安装成功"
        SYSTEM_LIBZIP=$(find /usr/lib /lib -name 'libzip.so*' 2>/dev/null | head -1)
        [ -n "$SYSTEM_LIBZIP" ] && cp "$SYSTEM_LIBZIP" ./lib/libzip.so.5 && echo "  复制: $SYSTEM_LIBZIP"
    else
        echo "  apt-get 不可用，继续..."
    fi
fi

# ── 方案3：手动下载 .deb 并用 ar+tar 解包（无需任何特权工具）──
echo "▶ 准备 libzip.so.5（ar+tar 解包）..."
python3 - << 'PYEOF'
import urllib.request, subprocess, os, glob, shutil, sys

os.makedirs('./lib', exist_ok=True)

def extract_deb_ar(deb_path, extract_dir):
    """用 ar x + tar xf 解包 .deb，不依赖 dpkg-deb"""
    shutil.rmtree(extract_dir, ignore_errors=True)
    os.makedirs(extract_dir, exist_ok=True)

    # 1. ar x 解包（.deb = ar 归档）
    r = subprocess.run(
        ['ar', 'x', os.path.abspath(deb_path)],
        cwd=extract_dir, capture_output=True, text=True
    )
    if r.returncode != 0:
        raise RuntimeError(f"ar x 失败: {r.stderr.strip()}")

    ar_files = os.listdir(extract_dir)
    print(f"  ar 解包文件: {ar_files}", flush=True)

    # 2. 找 data.tar.* 并解包
    data_tars = [f for f in ar_files if f.startswith('data.tar')]
    if not data_tars:
        raise RuntimeError(f"未找到 data.tar.*，ar 内容: {ar_files}")

    data_tar = os.path.join(extract_dir, data_tars[0])
    content_dir = os.path.join(extract_dir, 'content')
    os.makedirs(content_dir, exist_ok=True)

    r2 = subprocess.run(
        ['tar', 'xf', data_tar, '-C', content_dir],
        capture_output=True, text=True
    )
    if r2.returncode != 0:
        raise RuntimeError(f"tar xf 失败: {r2.stderr.strip()}")

    return content_dir

# 已经有 libzip.so.5 则跳过
if os.path.exists('./lib/libzip.so.5'):
    print("✓ libzip.so.5 已存在，跳过下载", flush=True)
else:
    urls = [
        ("http://archive.ubuntu.com/ubuntu/pool/main/libz/libzip/libzip5_1.7.3-1_amd64.deb",         "libzip5 focal"),
        ("http://security.ubuntu.com/ubuntu/pool/main/libz/libzip/libzip5_1.7.3-1ubuntu0.1_amd64.deb","libzip5 focal-security"),
        ("http://archive.ubuntu.com/ubuntu/pool/main/libz/libzip/libzip4_1.7.3-1ubuntu2_amd64.deb",   "libzip4 jammy"),
    ]

    for url, label in urls:
        print(f"\n  [{label}] 下载 {url}", flush=True)
        try:
            urllib.request.urlretrieve(url, '/tmp/libzip_pkg.deb')
            size = os.path.getsize('/tmp/libzip_pkg.deb')
            print(f"  下载完成 {size} bytes", flush=True)

            content_dir = extract_deb_ar('/tmp/libzip_pkg.deb', '/tmp/lz_ext')

            found = glob.glob(f'{content_dir}/**/*libzip*.so*', recursive=True)
            print(f"  找到 so 文件: {found}", flush=True)

            for f in found:
                if os.path.isfile(f):
                    dst = os.path.join('./lib', os.path.basename(f))
                    shutil.copy2(f, dst)
                    print(f"  复制: {os.path.basename(f)}", flush=True)

            if glob.glob('./lib/libzip.so*'):
                print(f"  ✓ 提取成功", flush=True)
                break
        except Exception as e:
            print(f"  ✗ 失败: {e}", flush=True)

    # 统一命名为 libzip.so.5
    if not os.path.exists('./lib/libzip.so.5'):
        for candidate in sorted(glob.glob('./lib/libzip.so*')):
            shutil.copy2(candidate, './lib/libzip.so.5')
            print(f"  别名: {os.path.basename(candidate)} → libzip.so.5", flush=True)
            break

    # 最后兜底：从系统目录复制
    if not os.path.exists('./lib/libzip.so.5'):
        print("  从系统目录查找 libzip...", flush=True)
        for d in ['/usr/lib/x86_64-linux-gnu', '/usr/lib', '/lib/x86_64-linux-gnu', '/lib']:
            for f in glob.glob(f'{d}/libzip.so*'):
                shutil.copy2(f, './lib/libzip.so.5')
                print(f"  系统复制: {f}", flush=True)
                break
            if os.path.exists('./lib/libzip.so.5'):
                break

print(f"\nlib 目录: {os.listdir('./lib') if os.path.exists('./lib') else '空'}", flush=True)
if os.path.exists('./lib/libzip.so.5'):
    import struct
    size = os.path.getsize('./lib/libzip.so.5')
    print(f"✓ libzip.so.5 准备完成 ({size} bytes)")
else:
    print("✗ 错误: libzip.so.5 未能准备")
    sys.exit(1)
PYEOF

# 确认 libzip.so.5 已就位
if [ ! -f "./lib/libzip.so.5" ]; then
    echo "✗ libzip.so.5 缺失，终止构建"
    exit 1
fi
echo "✓ libzip.so.5: $(ls -lh ./lib/libzip.so.5 | awk '{print $5}')"

# v1.14.1 eigen（CPU纯计算版）是最后一个提供 Linux CPU 预编译二进制的稳定版本
KATAGO_VERSION="v1.14.1"
# 注意：文件名格式是 eigen-linux-x64，不是 cpu-linux-x86_64
KATAGO_URL="https://github.com/lightvector/KataGo/releases/download/${KATAGO_VERSION}/katago-${KATAGO_VERSION}-eigen-linux-x64.zip"

# ── 下载 KataGo 引擎 ──────────────────────────────────────
if [ ! -f "katago" ]; then
    echo "▶ 下载 KataGo ${KATAGO_VERSION} (Eigen/CPU 版)..."
    wget --timeout=120 "${KATAGO_URL}" -O katago.zip
    if [ $? -ne 0 ]; then
        echo "✗ 下载失败，请检查网络或 URL: ${KATAGO_URL}"
        exit 1
    fi
    unzip -q katago.zip
    # zip 内可能有子目录，找到实际二进制
    FOUND=$(find . -maxdepth 3 -name "katago" -not -name "*.zip" -type f | head -1)
    if [ -z "$FOUND" ]; then
        echo "ZIP 内容如下（帮助排查）："
        unzip -l katago.zip | head -20
        echo "✗ 未找到 katago 二进制"
        exit 1
    fi
    # 只在不是同一文件时才复制（zip 可能直接解压到 ./katago）
    if [ "$(realpath "$FOUND")" != "$(realpath ./katago 2>/dev/null || echo '')" ]; then
        cp "$FOUND" ./katago
    fi
    chmod +x ./katago
    rm -f katago.zip
    echo "✓ KataGo 下载完成（来源: $FOUND）"
else
    echo "✓ KataGo 已存在，跳过"
fi

# 验证二进制可执行
./katago version 2>&1 | head -3 || { echo "✗ KataGo 无法运行"; exit 1; }

# ── 下载围棋模型 ──────────────────────────────────────────
mkdir -p models

if [ ! -f "models/model.bin.gz" ]; then
    echo "▶ 下载 KataGo 模型（kata1-b18c384，约80MB）..."
    echo "  （此步骤可能需要 1-3 分钟，请耐心等待）"

    # kata1-b18c384 系列：18层网络，综合强度 / 下载体积的最佳平衡
    MODEL_URL="https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-b18c384nbt-s9131461376-d4087399203.bin.gz"

    wget -q --show-progress "${MODEL_URL}" -O models/model.bin.gz || {
        echo "⚠ 主模型下载失败，尝试备用较小模型（b15c192，约30MB）..."
        FALLBACK_URL="https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-b15c192nbt-s7709731328-d3715293823.bin.gz"
        wget -q --show-progress "${FALLBACK_URL}" -O models/model.bin.gz
    }
    echo "✓ 模型下载完成"
else
    echo "✓ 模型已存在，跳过"
fi

echo ""
echo "════════════════════════════════"
echo "  构建完成！"
echo "  KataGo:  $(./katago version 2>&1 | head -1)"
echo "  模型:    $(ls -lh models/model.bin.gz | awk '{print $5}')"
echo "════════════════════════════════"
