"""
KataGo GTP Bridge Server  —  Z.X.T 围棋 AI 后端
====================================================
使用 Flask（纯 Python，兼容所有版本），
将浏览器前端的对局请求转发给本机 KataGo 引擎。
"""

import os
import subprocess
import threading
import time
import logging
from flask import Flask, request, jsonify

# ─── 日志 ─────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s",
)
logger = logging.getLogger(__name__)

# ─── 配置 ─────────────────────────────────────────────────
KATAGO_BIN  = os.environ.get("KATAGO_BIN",  "./katago")
MODEL_PATH  = os.environ.get("MODEL_PATH",  "./models/model.bin.gz")
CONFIG_PATH = os.environ.get("CONFIG_PATH", "./gtp.cfg")
PORT        = int(os.environ.get("PORT", 8080))

VISITS = {"easy": 50, "medium": 200, "hard": 500}


# ─── KataGo GTP 进程封装 ──────────────────────────────────
class KataGoEngine:
    def __init__(self):
        self.process = None
        self.lock = threading.Lock()
        self._start()

    def _start(self):
        logger.info("正在启动 KataGo 引擎，加载模型中…")

        # 把 ./lib 目录加入动态库搜索路径，确保 KataGo 能找到 libzip.so.5
        env = os.environ.copy()
        lib_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib")
        if os.path.exists(lib_dir):
            old = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = f"{lib_dir}:{old}" if old else lib_dir
            logger.info(f"LD_LIBRARY_PATH → {env['LD_LIBRARY_PATH']}")
            logger.info(f"lib 目录内容: {os.listdir(lib_dir)}")
        else:
            logger.warning(f"lib 目录不存在: {lib_dir}")

        self.process = subprocess.Popen(
            [KATAGO_BIN, "gtp", "-model", MODEL_PATH, "-config", CONFIG_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,   # ← 关键：把 LD_LIBRARY_PATH 传给 KataGo 进程
        )
        time.sleep(5)
        if self.process.poll() is not None:
            err = self.process.stderr.read()
            raise RuntimeError(f"KataGo 启动失败: {err}")
        logger.info("KataGo 引擎就绪 ✓")

    def _ensure_alive(self):
        if self.process is None or self.process.poll() is not None:
            logger.warning("KataGo 进程已退出，尝试重启…")
            self._start()

    def _send(self, command):
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()

        is_error = False
        got_header = False
        lines = []

        while True:
            raw = self.process.stdout.readline()
            if not raw:
                raise IOError("KataGo 进程意外关闭")
            line = raw.rstrip("\r\n")

            if not got_header:
                if line.startswith("="):
                    got_header = True
                    body = line[1:].strip()
                    if body:
                        lines.append(body)
                elif line.startswith("?"):
                    got_header = True
                    is_error = True
                    body = line[1:].strip()
                    if body:
                        lines.append(body)
            else:
                if line == "":
                    break
                lines.append(line)

        result = "\n".join(lines).strip()
        if is_error:
            raise RuntimeError(f"GTP 错误 [{command!r}]: {result}")
        return result

    def get_move(self, board_size, moves, to_play, komi, difficulty):
        visits = VISITS.get(difficulty, 500)
        with self.lock:
            self._ensure_alive()
            self._send(f"boardsize {board_size}")
            self._send(f"komi {komi}")
            self._send("clear_board")
            for mv in moves:
                self._send(f"play {mv['color']} {mv['pos']}")
            self._send(f"kata-set-param maxVisits {visits}")
            result = self._send(f"genmove {to_play}")
            return result.lower().strip()


# ─── 启动引擎 ─────────────────────────────────────────────
engine = None
engine_error = None
try:
    # 打印关键路径，方便排查
    logger.info(f"KataGo 路径: {os.path.abspath(KATAGO_BIN)}, 存在: {os.path.exists(KATAGO_BIN)}")
    logger.info(f"模型路径:   {os.path.abspath(MODEL_PATH)}, 存在: {os.path.exists(MODEL_PATH)}")
    logger.info(f"配置路径:   {os.path.abspath(CONFIG_PATH)}, 存在: {os.path.exists(CONFIG_PATH)}")
    engine = KataGoEngine()
except Exception as e:
    engine_error = str(e)
    logger.error(f"引擎初始化失败: {e}")


# ─── Flask 应用 ───────────────────────────────────────────
app = Flask(__name__)


@app.after_request
def add_cors(response):
    """允许跨域（Netlify 游戏页面调用本服务器）"""
    response.headers["Access-Control-Allow-Origin"]  = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return response


@app.route("/", methods=["GET"])
def health():
    return jsonify({
        "status":        "ok" if engine is not None else "engine_not_ready",
        "engine_ready":  engine is not None,
        "error":         engine_error,
        "katago_exists": os.path.exists(KATAGO_BIN),
        "model_exists":  os.path.exists(MODEL_PATH),
        "config_exists": os.path.exists(CONFIG_PATH),
    })


@app.route("/api/move", methods=["POST", "OPTIONS"])
def get_move():
    # 浏览器跨域预检请求
    if request.method == "OPTIONS":
        return "", 204

    if engine is None:
        return jsonify({"error": "引擎未就绪，请稍后重试"}), 503

    data = request.get_json()
    if not data:
        return jsonify({"error": "请求体不能为空"}), 400

    try:
        move = engine.get_move(
            board_size=data["board_size"],
            moves=data.get("moves", []),
            to_play=data["to_play"],
            komi=data.get("komi", 6.5),
            difficulty=data.get("difficulty", "medium"),
        )
        return jsonify({
            "move":      move,
            "is_pass":   move == "pass",
            "is_resign": move == "resign",
        })
    except Exception as e:
        logger.error(f"获取落子失败: {e}")
        return jsonify({"error": str(e)}), 500


# ─── 入口 ─────────────────────────────────────────────────
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
