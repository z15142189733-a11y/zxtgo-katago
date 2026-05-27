FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

# 安装依赖：libzip5 是 KataGo eigen 二进制的硬依赖
RUN apt-get update && apt-get install -y \
    python3 python3-pip \
    wget unzip \
    libzip5 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── 下载并安装 KataGo v1.14.1 eigen (CPU版) ──
RUN wget -q "https://github.com/lightvector/KataGo/releases/download/v1.14.1/katago-v1.14.1-eigen-linux-x64.zip" \
      -O /tmp/katago.zip \
    && unzip -q /tmp/katago.zip -d /tmp/katago_extract \
    && find /tmp/katago_extract -name "katago" -type f -not -name "*.zip" \
         | head -1 \
         | xargs -I{} install -m 755 {} /usr/local/bin/katago \
    && rm -rf /tmp/katago.zip /tmp/katago_extract \
    && katago version

# ── 下载围棋神经网络模型（b18c384，URL 已验证有效）──
RUN mkdir -p /app/models \
    && wget -q "https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-b18c384nbt-s9131461376-d4087399203.bin.gz" \
         -O /app/models/model.bin.gz \
    && ls -lh /app/models/model.bin.gz

# ── Python 依赖 ──
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# ── 应用代码 ──
COPY main.py gtp.cfg ./

ENV KATAGO_BIN=/usr/local/bin/katago
ENV MODEL_PATH=/app/models/model.bin.gz
ENV CONFIG_PATH=/app/gtp.cfg
ENV PORT=10000

EXPOSE 10000

CMD flask --app main run --host 0.0.0.0 --port $PORT
