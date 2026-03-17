#!/usr/bin/env python3
"""
Gemini Business2API 自动注册脚本

功能：
  - 批量自动注册 Gemini Business 账号
  - 注册完成后自动验证 API 可用性
  - 支持命令行参数配置

依赖：
  - 需要已部署并运行的 gemini-business2api 服务
  - 服务需已配置好 DuckMail + 浏览器环境

用法：
  python auto_register.py                          # 使用默认配置注册 10 个
  python auto_register.py -n 5                     # 注册 5 个
  python auto_register.py -n 3 --verify            # 注册 3 个并验证 API
  python auto_register.py --host http://vps:7860   # 指定服务地址
  python auto_register.py --config config.json     # 使用配置文件
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime
from urllib.parse import urljoin

try:
    import requests
except ImportError:
    print("错误: 需要 requests 库，请运行: pip install requests")
    sys.exit(1)


# ─────────────────────────── 默认配置 ───────────────────────────

DEFAULT_CONFIG = {
    "host": "http://localhost:7860",
    "admin_key": "",
    "count": 10,
    "mail_provider": "duckmail",
    "domain": "duckmail.sbs",
    "poll_interval": 15,
    "verify_api": True,
    "verify_model": "gemini-2.5-flash",
    "verify_prompt": "回复OK",
}


# ─────────────────────────── 工具函数 ───────────────────────────

def log(msg, level="INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    prefix = {"INFO": "✓", "WARN": "⚠", "ERROR": "✗", "STEP": "→"}.get(level, " ")
    print(f"[{ts}] {prefix} {msg}")


def load_config(config_path):
    """加载配置文件，与默认配置合并"""
    cfg = DEFAULT_CONFIG.copy()
    if config_path and os.path.isfile(config_path):
        with open(config_path, "r", encoding="utf-8") as f:
            user_cfg = json.load(f)
        cfg.update(user_cfg)
        log(f"已加载配置文件: {config_path}")
    return cfg


# ─────────────────────────── API 客户端 ───────────────────────────

class GeminiAPIClient:
    """gemini-business2api 管理 API 客户端"""

    def __init__(self, host, admin_key):
        self.host = host.rstrip("/")
        self.admin_key = admin_key
        self.session = requests.Session()
        self.session.headers.update({"Content-Type": "application/json"})

    def _url(self, path):
        return f"{self.host}{path}"

    def login(self):
        """登录管理面板，获取 session cookie"""
        resp = self.session.post(
            self._url("/login"),
            data={"admin_key": self.admin_key},
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if resp.status_code == 200:
            data = resp.json()
            if data.get("success"):
                return True
        log(f"登录失败: HTTP {resp.status_code} {resp.text[:200]}", "ERROR")
        return False

    def health_check(self):
        """检查服务健康状态"""
        try:
            resp = self.session.get(self._url("/health"), timeout=10)
            return resp.status_code == 200 and resp.json().get("status") == "ok"
        except Exception as e:
            log(f"健康检查失败: {e}", "ERROR")
            return False

    def get_accounts(self):
        """获取账号列表"""
        resp = self.session.get(self._url("/admin/accounts"))
        if resp.status_code == 200:
            return resp.json()
        return None

    def start_register(self, count, mail_provider, domain):
        """启动注册任务"""
        payload = {
            "count": count,
            "mail_provider": mail_provider,
            "domain": domain,
        }
        resp = self.session.post(self._url("/admin/register/start"), json=payload)
        if resp.status_code == 200:
            return resp.json()
        log(f"启动注册失败: HTTP {resp.status_code} {resp.text[:200]}", "ERROR")
        return None

    def get_register_current(self):
        """获取当前注册任务状态"""
        resp = self.session.get(self._url("/admin/register/current"))
        if resp.status_code == 200:
            return resp.json()
        return None

    def get_register_task(self, task_id):
        """获取指定注册任务详情"""
        resp = self.session.get(self._url(f"/admin/register/task/{task_id}"))
        if resp.status_code == 200:
            return resp.json()
        return None

    def chat_completions(self, model, prompt, api_key=None):
        """调用 OpenAI 兼容 API"""
        headers = {"Content-Type": "application/json"}
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 50,
        }
        resp = requests.post(
            self._url("/v1/chat/completions"),
            json=payload,
            headers=headers,
            timeout=60,
        )
        if resp.status_code == 200:
            return resp.json()
        return None


# ─────────────────────────── 注册流程 ───────────────────────────

def wait_for_task(client, task_id, total, poll_interval):
    """轮询等待注册任务完成"""
    start_time = time.time()
    last_progress = -1

    while True:
        time.sleep(poll_interval)

        # 重新登录防止 session 过期
        client.login()
        current = client.get_register_current()

        if current is None:
            log("获取任务状态失败，重试...", "WARN")
            continue

        status = current.get("status", "unknown")

        if status == "idle":
            # 任务已完成，尝试获取最终详情
            elapsed = time.time() - start_time
            log(f"任务完成，总耗时 {elapsed:.0f} 秒")
            return current

        progress = current.get("progress", 0)
        success = current.get("success_count", 0)
        fail = current.get("fail_count", 0)

        if progress != last_progress:
            last_progress = progress
            elapsed = time.time() - start_time
            log(f"进度: {progress}/{total}  成功: {success}  失败: {fail}  耗时: {elapsed:.0f}s")

            # 打印最新关键日志
            logs = current.get("logs", [])
            for entry in logs[-3:]:
                msg = entry.get("message", "")
                level = entry.get("level", "info")
                if any(k in msg for k in ["成功", "失败", "验证码", "错误"]):
                    log_level = "ERROR" if "失败" in msg or "错误" in msg else "INFO"
                    log(f"  {msg}", log_level)

    return None


def run_register(client, cfg):
    """执行注册流程"""
    count = cfg["count"]
    mail_provider = cfg["mail_provider"]
    domain = cfg["domain"]
    poll_interval = cfg["poll_interval"]

    # 获取注册前的账号数
    pre_accounts = client.get_accounts()
    pre_count = pre_accounts["total"] if pre_accounts else 0
    log(f"当前已有 {pre_count} 个账号")

    # 启动注册
    log(f"启动注册任务: {count} 个账号 (邮箱={mail_provider}, 域名={domain})", "STEP")
    task = client.start_register(count, mail_provider, domain)
    if not task:
        log("启动注册任务失败", "ERROR")
        return False

    task_id = task.get("id")
    log(f"任务 ID: {task_id}")

    # 等待完成
    wait_for_task(client, task_id, count, poll_interval)

    # 重新登录后获取最终账号列表
    client.login()
    post_accounts = client.get_accounts()
    if not post_accounts:
        log("获取账号列表失败", "ERROR")
        return False

    post_count = post_accounts["total"]
    new_count = post_count - pre_count
    log(f"注册完成: 新增 {new_count} 个账号，总计 {post_count} 个")

    # 打印新账号
    accounts = post_accounts.get("accounts", [])
    print()
    print(f"{'#':>3}  {'邮箱':<42} {'状态':<6} {'剩余时间':<10} {'可用'}")
    print("─" * 80)
    for i, acc in enumerate(accounts, 1):
        avail = "是" if acc.get("is_available") else "否"
        print(f"{i:3d}  {acc['id']:<42} {acc['status']:<6} {acc['remaining_display']:<10} {avail}")
    print()

    return new_count > 0


# ─────────────────────────── API 验证 ───────────────────────────

def verify_api(client, cfg):
    """验证 API 可用性"""
    model = cfg["verify_model"]
    prompt = cfg["verify_prompt"]

    log(f"验证 API: 模型={model}", "STEP")

    result = client.chat_completions(model, prompt)
    if result and "choices" in result:
        content = result["choices"][0]["message"]["content"]
        log(f"API 验证成功! 模型回复: {content[:100]}")
        return True
    else:
        log("API 验证失败", "ERROR")
        return False


# ─────────────────────────── 主函数 ───────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Gemini Business2API 自动注册脚本",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python auto_register.py -n 10 -k YOUR_ADMIN_KEY
  python auto_register.py -n 5 --host http://vps:7860 --verify
  python auto_register.py --config config.json
        """,
    )
    parser.add_argument("-n", "--count", type=int, help="注册账号数量 (默认: 10)")
    parser.add_argument("-k", "--admin-key", type=str, help="管理面板 ADMIN_KEY")
    parser.add_argument("--host", type=str, help="服务地址 (默认: http://localhost:7860)")
    parser.add_argument("--domain", type=str, help="邮箱域名 (默认: duckmail.sbs)")
    parser.add_argument("--mail-provider", type=str, help="邮箱提供商 (默认: duckmail)")
    parser.add_argument("--verify", action="store_true", default=None, help="注册后验证 API 可用性")
    parser.add_argument("--no-verify", action="store_true", help="跳过 API 验证")
    parser.add_argument("--config", type=str, help="配置文件路径 (JSON)")
    parser.add_argument("--poll-interval", type=int, help="轮询间隔秒数 (默认: 15)")

    args = parser.parse_args()

    # 加载配置
    cfg = load_config(args.config)

    # 命令行参数覆盖配置文件
    if args.count is not None:
        cfg["count"] = args.count
    if args.admin_key:
        cfg["admin_key"] = args.admin_key
    if args.host:
        cfg["host"] = args.host
    if args.domain:
        cfg["domain"] = args.domain
    if args.mail_provider:
        cfg["mail_provider"] = args.mail_provider
    if args.poll_interval:
        cfg["poll_interval"] = args.poll_interval
    if args.verify is True:
        cfg["verify_api"] = True
    if args.no_verify:
        cfg["verify_api"] = False

    # 环境变量兜底
    if not cfg["admin_key"]:
        cfg["admin_key"] = os.environ.get("ADMIN_KEY", "")
    if not cfg["admin_key"]:
        log("错误: 未提供 ADMIN_KEY，使用 -k 参数或设置 ADMIN_KEY 环境变量", "ERROR")
        sys.exit(1)

    # 开始
    print()
    print("═" * 60)
    print("  Gemini Business2API 自动注册")
    print("═" * 60)
    print(f"  服务地址:    {cfg['host']}")
    print(f"  注册数量:    {cfg['count']}")
    print(f"  邮箱提供商:  {cfg['mail_provider']}")
    print(f"  邮箱域名:    {cfg['domain']}")
    print(f"  API 验证:    {'是' if cfg['verify_api'] else '否'}")
    print("═" * 60)
    print()

    client = GeminiAPIClient(cfg["host"], cfg["admin_key"])

    # 1. 健康检查
    log("检查服务状态...", "STEP")
    if not client.health_check():
        log(f"服务不可用: {cfg['host']}", "ERROR")
        sys.exit(1)
    log("服务正常")

    # 2. 登录
    log("登录管理面板...", "STEP")
    if not client.login():
        log("登录失败，请检查 ADMIN_KEY", "ERROR")
        sys.exit(1)
    log("登录成功")

    # 3. 注册
    success = run_register(client, cfg)
    if not success:
        log("注册流程异常", "ERROR")
        sys.exit(1)

    # 4. 验证 API
    if cfg["verify_api"]:
        # 重新登录确保 session 有效
        client.login()
        verify_api(client, cfg)

    print()
    log("全部完成!")
    print()


if __name__ == "__main__":
    main()
