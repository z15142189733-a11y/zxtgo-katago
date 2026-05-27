#!/bin/bash
# ============================================================
# build.sh  —  Render 部署时自动执行：下载 KataGo + 围棋模型
# ============================================================
set -e

# ── 准备 KataGo 运行所需的系统库（用 Python 下载解压，无需 root）──
echo "▶ 准备 libzip.so.5 依赖..."
python3 - << 'PYEOF'
import urllib.request, subprocess, os, glob, shutil, sys

os.makedirs('./lib', exist_ok=True)

def try_download_extract(url, label):
    print(f"  尝试: {label}")
    try:
        urllib.request.urlretrieve(url, '/tmp/libzip_pkg.deb')
        os.makedirs('/tmp/lz_ext', exist_ok=True)
        subprocess.run(['dpkg-deb', '-x', '/tmp/libzip_pkg.deb', '/tmp/lz_ext'],
                       check=True, capture_output=True)
        found = glob.glob('/tmp/lz_ext/**/*libzip*', recursive=True)
        for f in found:
            if os.path.isfile(f):
                dst = os.path.join('./lib', os.path.basename(f))
                shutil.copy2(f, dst)
                print(f"  复制: {os.path.basename(f)}")
        return True
    except Exception as e:
        print(f"  失败: {e}")
        return False

# 尝试 Ubuntu 20.04 的 libzip5（和 KataGo eigen 二进制编译版本一致）
urls = [
    ("http://archive.ubuntu.com/ubuntu/pool/main/libz/libzip/libzip5_1.7.3-1_amd64.deb", "libzip5 focal"),
    ("http://security.ubuntu.com/ubuntu/pool/main/libz/libzip/libzip5_1.7.3-1ubuntu0.1_amd64.deb", "libzip5 focal-security"),
    ("http://archive.ubuntu.com/ubuntu/pool/main/libz/libzip/libzip4_1.7.3-1ubuntu2_amd64.deb", "libzip4 jammy"),
]

for url, label in urls:
    if try_download_extract(url, label):
        break

# 确保最终有 libzip.so.5 这个名字（无论下载的是哪个版本）
if not os.path.exists('./lib/libzip.so.5'):
    candidates = sorted(glob.glob('./lib/libzip.so*'))
    if candidates:
        shutil.copy2(candidates[0], './lib/libzip.so.5')
        print(f"  创建别名: {candidates[0]} → libzip.so.5")

# 如果下载都失败，尝试从系统复制
if not os.path.exists('./lib/libzip.so.5'):
    for search_dir in ['/usr/lib/x86_64-linux-gnu', '/usr/lib', '/lib']:
        found = glob.glob(f'{search_dir}/libzip.so*')
        if found:
            shutil.copy2(found[0], './lib/libzip.so.5')
            print(f"  从系统复制: {found[0]}")
            break

print(f"lib 目录: {os.listdir('./lib') if os.path.exists('./lib') else '空'}")
if os.path.exists('./lib/libzip.so.5'):
    print("✓ libzip.so.5 准备完成")
else:
    print("⚠ libzip.so.5 未能准备，KataGo 可能启动失败")
PYEOF

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
