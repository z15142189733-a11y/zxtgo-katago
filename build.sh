#!/bin/bash
# ============================================================
# build.sh  —  Render 部署时自动执行：下载 KataGo + 围棋模型
# ============================================================
set -e

KATAGO_VERSION="v1.14.0"
KATAGO_URL="https://github.com/lightvector/KataGo/releases/download/${KATAGO_VERSION}/katago-${KATAGO_VERSION}-cpu-linux-x86_64.zip"

# ── 下载 KataGo 引擎 ──────────────────────────────────────
if [ ! -f "katago" ]; then
    echo "▶ 下载 KataGo ${KATAGO_VERSION} (CPU 版)..."
    wget -q --show-progress "${KATAGO_URL}" -O katago.zip
    unzip -q katago.zip
    # zip 内可能有子目录，找到实际二进制
    FOUND=$(find . -maxdepth 3 -name "katago" -type f | head -1)
    if [ -z "$FOUND" ]; then
        echo "✗ 未找到 katago 二进制，请检查 ZIP 结构"
        exit 1
    fi
    cp "$FOUND" ./katago
    chmod +x ./katago
    rm -f katago.zip
    echo "✓ KataGo 下载完成"
else
    echo "✓ KataGo 已存在，跳过"
fi

# 验证二进制可执行
./katago version || { echo "✗ KataGo 无法运行，架构不匹配？"; exit 1; }

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
