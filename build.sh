#!/bin/bash
# ============================================================
# build.sh  —  Render 部署时自动执行：下载 KataGo + 围棋模型
# ============================================================
set -e

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
    cp "$FOUND" ./katago
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
