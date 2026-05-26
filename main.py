"""
KataGo GTP Bridge Server  —  Z.X.T 围棋 AI 后端
====================================================
将浏览器前端的对局请求转发给本机 KataGo 引擎，
返回最佳落子坐标。支持三档难度（思考量不同）。
"""

import os
import subprocess
import threading
import time
import logging
from contextlib import asynccontextmanager
from typing import List, Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# ─── 日志 ────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s",
)
logger = logging.getLogger(__name__)

# ─── 配置（可通过环境变量覆盖）──────────────────────────
KATAGO_BIN  = os.environ.get("KATAGO_BIN",  "./katago")
MODEL_PATH  = os.environ.get("MODEL_PATH",  "./models/model.bin.gz")
CONFIG_PATH = os.environ.get("CONFIG_PATH", "./gtp.cfg")
PORT        = int(os.environ.get("PORT", 8080))

# 三档难度的 MCTS 思考量（访问次数）
# easy  ~20-30 kyu │ medium ~5-10 kyu │ hard ~1-3 kyu
VISITS = {"easy": 50, "medium": 500, "hard": 3000}


# ─── KataGo GTP 进程封装 ─────────────────────────────────
class KataGoEngine:
    """管理一个持久的 KataGo GTP 子进程，线程安全。"""

    def __init__(self):
        self.process: Optional[subprocess.Popen] = None
        self.lock = threading.Lock()
        self._start()

    def _start(self):
        logger.info("正在启动 KataGo 引擎，加载模型中…")
        self.process = subprocess.Popen(
            [KATAGO_BIN, "gtp", "-model", MODEL_PATH, "-config", CONFIG_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        # 等待引擎初始化（模型加载约 3-8 秒）
        time.sleep(5)
        if self.process.poll() is not None:
            err = self.process.stderr.read()
            raise RuntimeError(f"KataGo 启动失败: {err}")
        logger.info("KataGo 引擎就绪 ✓")

    def _ensure_alive(self):
        if self.process is None or self.process.poll() is not None:
            logger.warning("KataGo 进程已退出，尝试重启…")
            self._start()

    def _send(self, command: str) -> str:
        """
        发送一条 GTP 命令，读取并返回完整响应文本。
        GTP 响应格式：
            = [可选id] 响应内容\n
            \n           （空行表示结束）
        """
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()

        is_error = False
        got_header = False
        lines: List[str] = []

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
                # 忽略启动时的其他输出行
            else:
                if line == "":
                    break  # 空行 = 响应结束
                lines.append(line)

        result = "\n".join(lines).strip()
        if is_error:
            raise RuntimeError(f"GTP 错误 [{command!r}]: {result}")
        return result

    def get_move(
        self,
        board_size: int,
        moves: list,
        to_play: str,
        komi: float,
        difficulty: str,
    ) -> str:
        """
        初始化棋盘、重放棋谱、设置思考量，然后请求 KataGo 给出落子。
        返回 GTP 格式坐标（如 "D4"）或 "pass" / "resign"。
        """
        visits = VISITS.get(difficulty, 500)

        with self.lock:
            self._ensure_alive()

            self._send(f"boardsize {board_size}")
            self._send(f"komi {komi}")
            self._send("clear_board")

            for mv in moves:
                color = mv["color"]   # "black" / "white"
                pos   = mv["pos"]     # "D4" / "pass"
                self._send(f"play {color} {pos}")

            # kata-set-param 允许在运行时更改思考量
            self._send(f"kata-set-param maxVisits {visits}")

            result = self._send(f"genmove {to_play}")
            return result.lower().strip()


# ─── 全局引擎实例 ─────────────────────────────────────────
engine: Optional[KataGoEngine] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global engine
    try:
        engine = KataGoEngine()
    except Exception as exc:
        logger.error(f"引擎初始化失败: {exc}")
        engine = None
    yield
    # 关闭时终止子进程
    if engine and engine.process:
        try:
            engine.process.terminate()
            engine.process.wait(timeout=5)
        except Exception:
            pass


# ─── FastAPI 应用 ─────────────────────────────────────────
app = FastAPI(title="Z.X.T 围棋 KataGo API", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],   # 允许任意来源（家人/朋友直接访问游戏链接）
    allow_methods=["*"],
    allow_headers=["*"],
)


# ─── 请求 / 响应数据模型 ──────────────────────────────────
class MoveEntry(BaseModel):
    color: str  # "black" 或 "white"
    pos: str    # GTP 坐标，如 "D4"，或 "pass"


class MoveRequest(BaseModel):
    board_size: int             # 棋盘路数：9 / 13 / 19
    moves: List[MoveEntry]      # 已下棋谱（GTP 格式）
    to_play: str                # 本手颜色："black" / "white"
    komi: float = 6.5           # 贴目
    difficulty: str = "medium"  # "easy" / "medium" / "hard"


class MoveResponse(BaseModel):
    move: str        # GTP 坐标或 "pass" / "resign"
    is_pass: bool
    is_resign: bool


# ─── API 路由 ─────────────────────────────────────────────
@app.get("/")
async def health_check():
    """健康检查，可用于监测服务是否在线。"""
    return {
        "status": "ok" if engine is not None else "engine_not_ready",
        "engine_ready": engine is not None,
    }


@app.post("/api/move", response_model=MoveResponse)
async def get_best_move(req: MoveRequest):
    """
    接收当前棋局状态，返回 KataGo 的最佳落子。
    前端需要将整局棋谱（GTP 格式）随请求一起发送。
    """
    if engine is None:
        raise HTTPException(status_code=503, detail="KataGo 引擎未就绪，请稍后重试")

    try:
        move = engine.get_move(
            board_size=req.board_size,
            moves=[m.dict() for m in req.moves],
            to_play=req.to_play,
            komi=req.komi,
            difficulty=req.difficulty,
        )
        is_pass   = move in ("pass",)
        is_resign = move in ("resign",)
        return MoveResponse(move=move, is_pass=is_pass, is_resign=is_resign)

    except Exception as exc:
        logger.error(f"获取落子失败: {exc}")
        raise HTTPException(status_code=500, detail=f"引擎错误: {exc}")


# ─── 入口 ────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)
