#!/usr/bin/env python3
"""
抖音续火助手 - HTTP 回调监听服务器
监听浏览器执行脚本 (UserScript) 发送的完成信号。

用法: python3 callback_server.py [端口] [超时秒数]
退出码: 0=任务成功 1=超时未收到回调 2=错误 3=任务失败(部分或全部)
状态文件: 收到最终回调时写入同目录 last_callback.json，供调度脚本读取
"""

import sys
import json
import threading
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler

STATE_FILE = Path(__file__).resolve().parent / 'last_callback.json'


class CallbackHandler(BaseHTTPRequestHandler):
    """处理浏览器执行脚本发送的 POST /done 回调请求"""
    result = None

    def do_POST(self):
        if self.path != '/done':
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        try:
            payload = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            payload = {'raw': body.decode('utf-8', errors='replace')}

        # final=false 只是进度/重试通知，继续等待最终回调
        is_final = payload.get('final', True) if isinstance(payload, dict) else True
        status = payload.get('status', 'unknown') if isinstance(payload, dict) else 'unknown'

        if is_final:
            CallbackHandler.result = payload
            try:
                STATE_FILE.write_text(json.dumps(payload, ensure_ascii=False), encoding='utf-8')
            except OSError as error:
                print(f'写入状态文件失败: {error}', file=sys.stderr)

        print(f'[回调] final={is_final} status={status} {json.dumps(payload, ensure_ascii=False)}', flush=True)

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

        if is_final:
            # 在后台线程中关闭服务器，避免死锁
            threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, format, *args):
        # 静默日志输出，避免干扰调度脚本
        pass


def exit_code_for(payload):
    """按回调状态决定退出码"""
    if not isinstance(payload, dict):
        return 0
    status = payload.get('status', '')
    if status in ('partial', 'all_failed'):
        return 3
    return 0


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7788
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 300

    try:
        server = HTTPServer(('127.0.0.1', port), CallbackHandler)
    except OSError as e:
        print(f'无法启动服务器: {e}', file=sys.stderr)
        sys.exit(2)

    # 超时自动关闭
    timer = threading.Timer(timeout, server.shutdown)
    timer.daemon = True
    timer.start()

    server.serve_forever()
    timer.cancel()

    if CallbackHandler.result:
        sys.exit(exit_code_for(CallbackHandler.result))

    print('超时：未收到回调', file=sys.stderr)
    sys.exit(1)


if __name__ == '__main__':
    main()
