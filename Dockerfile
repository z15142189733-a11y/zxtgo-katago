FROM ubuntu:20.04

# 避免交互式 apt 提示
ENV DEBIAN_FRONTEND=noninteractive

# 安装 Python、libzip5（KataGo 依赖）、wget、unzip
RUN apt-get update && apt-get install -y \
    python3 python3-pip \
    wget unzip \
    libzip5 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── 下载 KataGo v1.14.1 eigen (CPU版) ──
RUN wget -q --show-progress \
    "https://github.com/lightvector/KataGo/releases/download/v1.14.1/katago-v1.14.1-eigen-linux-x64.zip" \
    -O katago.zip \
    && unzip -q katago.zip \
    && FOUND=$(find . -maxdepth 3 -name "katago" -type f | head -1) \
    && [ "$(realpath $FOUND)" != "$(realpath ./katago 2>/dev/null || echo x)" ] && cp "$FOUND" ./katago || true \
    && chmod +x ./katago \
    && rm -f katago.zip \
    && ./katago version

# ── 下载围棋神经网络模型 (~80MB) ──
RUN mkdir -p models && \
    wget -q --show-progress \
    "https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-b18c384nbt-s9131461376-d4087399203.bin.gz" \
    -O models/model.bin.gz \
    || wget -q --show-progress \
    "https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-b15c192nbt-s7709731328-d3715293823.bin.gz" \
    -O models/model.bin.gz

# ── 安装 Python 依赖 ──
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# ── 复制应用代码 ──
COPY main.py gtp.cfg ./

# ── 环境变量 ──
ENV KATAGO_BIN=/app/katago
ENV MODEL_PATH=/app/models/model.bin.gz
ENV CONFIG_PATH=/app/gtp.cfg
ENV PORT=10000

EXPOSE 10000

CMD flask --app main run --host 0.0.0.0 --port $PORT
