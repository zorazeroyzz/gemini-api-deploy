# Gemini Business2API 部署与管理工具集

gemini-business2api 项目的一键部署自动化脚本与账号管理工具。

## 一键部署

在全新服务器上一键部署 gemini-business2api 服务及管理工具：

```bash
curl -fsSL https://raw.githubusercontent.com/zorazeroyzz/gemini-api-deploy/main/deploy.sh -o deploy.sh
chmod +x deploy.sh
sudo ./deploy.sh
```

支持系统：OpenCloudOS 9 / RHEL 9 / CentOS 9 / Rocky Linux 9

部署内容：
- 安装 Python 3.11、Chromium、Xvfb 等全部依赖
- 克隆并构建 gemini-business2api 项目
- 配置服务参数（DuckMail + duckmail.sbs + headless=false）
- 部署 systemd 服务（开机自启）
- 部署账号管理脚本

部署完成后：
```bash
# 添加 10 个账号
/opt/gemini-business2api/register.sh 10

# 查看服务状态
/opt/gemini-business2api/status.sh

# 查看日志
journalctl -u gemini-b2api -f
```

## 前置条件（手动部署时）

- 已部署并运行 [gemini-business2api](https://github.com/Dreamy-rain/gemini-business2api) 服务
- 服务已配置好浏览器环境（Chromium + Xvfb）
- Python 3.8+ 和 `requests` 库

## 关键配置

| 配置项 | 推荐值 | 说明 |
|---|---|---|
| `browser_headless` | `false` | headless 模式会被检测拦截 |
| `temp_mail_provider` | `duckmail` | 无需 API Key 即可使用 |
| `domain` | `duckmail.sbs` | **必须**用此域名，其他域名会 403 |

## 使用方法

### 快速开始

```bash
# 添加 10 个账号（默认）
python auto_register.py -k YOUR_ADMIN_KEY

# 添加 5 个账号
python auto_register.py -n 5 -k YOUR_ADMIN_KEY

# 指定远程服务地址
python auto_register.py -n 10 -k YOUR_ADMIN_KEY --host http://vps:7860

# 跳过 API 验证
python auto_register.py -n 10 -k YOUR_ADMIN_KEY --no-verify
```

### 使用配置文件

```bash
cp config.example.json config.json
# 编辑 config.json 填入你的 admin_key
python auto_register.py --config config.json
```

### 使用环境变量

```bash
export ADMIN_KEY=your-admin-key
python auto_register.py -n 10
```

## 命令行参数

| 参数 | 说明 | 默认值 |
|---|---|---|
| `-n, --count` | 账号数量 | 10 |
| `-k, --admin-key` | 管理面板 ADMIN_KEY | 环境变量 `ADMIN_KEY` |
| `--host` | 服务地址 | `http://localhost:7860` |
| `--domain` | 邮箱域名 | `duckmail.sbs` |
| `--mail-provider` | 邮箱提供商 | `duckmail` |
| `--verify` | 完成后验证 API | 默认开启 |
| `--no-verify` | 跳过 API 验证 | - |
| `--config` | 配置文件路径 | - |
| `--poll-interval` | 轮询间隔(秒) | 15 |

## 运行示例

```
═══════════════════════════════════════════════════════════
  Gemini Business2API 账号管理
═══════════════════════════════════════════════════════════
  服务地址:    http://localhost:7860
  数量:        5
  邮箱提供商:  duckmail
  邮箱域名:    duckmail.sbs
  API 验证:    是
═══════════════════════════════════════════════════════════

[01:46:16] → 检查服务状态...
[01:46:16] ✓ 服务正常
[01:46:16] → 登录管理面板...
[01:46:16] ✓ 登录成功
[01:46:16] ✓ 当前已有 4 个账号
[01:46:16] → 启动任务: 5 个账号 (邮箱=duckmail, 域名=duckmail.sbs)
[01:46:16] ✓ 任务 ID: 2a959c1f-...
[01:47:27] ✓ 进度: 1/5  成功: 1  失败: 0  耗时: 71s
[01:48:28] ✓ 进度: 2/5  成功: 2  失败: 0  耗时: 132s
[01:49:28] ✓ 进度: 3/5  成功: 3  失败: 0  耗时: 192s
[01:50:28] ✓ 进度: 4/5  成功: 4  失败: 0  耗时: 252s
[01:51:28] ✓ 任务完成，总耗时 312 秒
[01:51:28] ✓ 完成: 新增 5 个账号，总计 9 个

  #  邮箱                                       状态   剩余时间   可用
────────────────────────────────────────────────────────────────────
  1  t7408giarrqjxde@duckmail.sbs               正常   11.6 小时  是
  2  t8518k3kby48pr5@duckmail.sbs               正常   12.0 小时  是
  ...

[01:51:29] → 验证 API: 模型=gemini-2.5-flash
[01:51:31] ✓ API 验证成功! 模型回复: OK

[01:51:31] ✓ 全部完成!
```

## 注意事项

- 每个账号处理耗时约 60-70 秒
- 账号 session 有效期约 12 小时，需配合服务端定时刷新功能
- DuckMail 公共 API 无速率限制，但建议合理使用
- 本工具仅限个人学习和技术研究，禁止商业用途
