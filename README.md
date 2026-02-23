# Gemini Business2API 一键部署

针对 OpenCloudOS 9 深度优化的全自动部署脚本，解决了原版在国内服务器上的常见问题。

## 特性

- **全自动无交互** — 所有参数通过命令行传入，适合脚本化部署
- **OpenCloudOS 9 适配** — 自动安装 Google Chrome（系统仓库无 chromium）
- **自动修复 pip** — OpenCloudOS 默认不装 pip，脚本自动处理
- **前端构建兼容** — 正确处理 vite 输出到 `../static/` 的情况
- **内置代理部署** — 自动部署 mihomo，支持 Base64 订阅自动解析
- **GeoIP 国内镜像** — 预下载 GeoIP 数据，避免启动卡住
- **GitHub 镜像加速** — 所有 GitHub 下载自动走国内镜像
- **设置 API 修复** — 使用正确的 PUT 方法更新配置

## 支持系统

OpenCloudOS 9 / RHEL 9 / CentOS 9 / Rocky Linux 9

## 快速开始

### 基础部署（无代理）

```bash
curl -fsSL https://raw.githubusercontent.com/zorazeroyzz/gemini-api-deploy/main/deploy.sh -o deploy.sh
chmod +x deploy.sh
sudo bash deploy.sh
```

### 带代理部署（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/zorazeroyzz/gemini-api-deploy/main/deploy.sh -o deploy.sh
chmod +x deploy.sh
sudo bash deploy.sh --clash-sub "你的订阅地址"
```

### 完整参数

```bash
sudo bash deploy.sh \
  --port 7860 \
  --admin-key "你的密钥" \
  --clash-sub "https://xxx/subscribe?token=xxx" \
  --clash-port 7890 \
  --ghproxy "https://ghfast.top"
```

## 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--port` | 7860 | 服务端口 |
| `--admin-key` | 自动生成 | 管理员密钥 |
| `--install-dir` | /opt/gemini-business2api | 安装目录 |
| `--clash-sub` | 空 | Clash 订阅地址（留空跳过代理） |
| `--clash-port` | 7890 | Clash HTTP 代理端口 |
| `--ghproxy` | https://ghfast.top | GitHub 镜像地址 |
| `--skip-clash` | - | 跳过代理部署 |
| `--skip-register` | - | 跳过自动注册脚本 |

## 部署完成后

```bash
# 查看状态
/opt/gemini-business2api/status.sh

# 注册账号
/opt/gemini-business2api/register.sh 10

# 查看日志
journalctl -u gemini-b2api -f

# 重启服务
systemctl restart gemini-b2api

# 卸载
/opt/gemini-business2api/uninstall.sh
```

## 部署内容

- **gemini-business2api** — 主服务（Python + FastAPI）
- **mihomo** — Clash Meta 代理（可选）
- **Xvfb** — 虚拟显示（浏览器自动化需要）
- **Google Chrome** — 浏览器引擎
- **自动注册脚本** — 批量注册 Gemini 账号

## 配置说明

部署脚本会自动配置以下注册参数：

| 配置项 | 值 | 说明 |
|--------|-----|------|
| browser_headless | false | headless 模式会被检测拦截 |
| temp_mail_provider | duckmail | 无需 API Key |
| domain | duckmail.sbs | 必须用此域名 |
| proxy_for_auth | http://127.0.0.1:7890 | 代理（如部署了 mihomo） |

## 与原版的区别

| 问题 | 原版 | 本版 |
|------|------|------|
| 交互式提示 | 多处 read 等待输入 | 全自动，命令行参数 |
| Chromium 安装 | dnf install chromium（OpenCloudOS 无此包） | 自动添加 Google Chrome 仓库 |
| pip 缺失 | 直接调用 pip 失败 | 自动检测并安装 pip |
| 前端构建检查 | 检查 frontend/dist/ | 兼容 vite 输出到 ../static/ |
| 设置 API | POST 方法（405 错误） | 正确使用 PUT 方法 |
| 代理订阅 | 仅支持 YAML 格式 | 自动解析 Base64 编码订阅 |
| GeoIP 数据 | 启动时在线下载（需翻墙） | 预下载国内镜像 |
| GitHub 访问 | 直连（国内超时） | 自动走 ghfast.top 镜像 |

## 故障排查

```bash
# 查看部署日志
tail -50 /var/log/gemini-b2api-deploy.log

# 查看服务日志
journalctl -u gemini-b2api -f

# 查看代理日志
journalctl -u mihomo -f

# 测试代理
curl -x http://127.0.0.1:7890 https://www.gstatic.com/generate_204

# 测试 Google 连通性
curl -x http://127.0.0.1:7890 https://accounts.google.com
```

## 致谢

- [gemini-business2api](https://github.com/Dreamy-rain/gemini-business2api) — 主项目
- [mihomo](https://github.com/MetaCubeX/mihomo) — Clash Meta 内核
