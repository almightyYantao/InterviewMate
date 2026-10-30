"""桌面 App：在本机空闲端口启动服务，用原生窗口打开界面。"""
from __future__ import annotations

import socket
import threading
import time

import uvicorn
import webview

from .web import app


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main() -> None:
    port = free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    threading.Thread(target=server.run, daemon=True).start()
    while not server.started:
        time.sleep(0.05)
    webview.create_window("简历筛选与一面准备", f"http://127.0.0.1:{port}/", width=1440, height=900, min_size=(1100, 700))
    webview.start()
    server.should_exit = True


if __name__ == "__main__":
    main()
