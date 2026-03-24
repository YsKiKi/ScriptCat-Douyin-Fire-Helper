# 抖音续火助手 - 调度脚本B

自动定时启动浏览器、等待脚本A（UserScript）完成续火任务后关闭浏览器。支持多账号顺序执行。

## 架构

```
脚本B (scheduler)                  脚本A (UserScript)
─────────────────                  ─────────────────
1. 读取 config.json
2. 等待到发送时间
3. 启动 callback_server (监听端口)
4. 启动浏览器 → 打开目标页面 ──→  5. Tampermonkey 自动注入执行
                                   6. 自动发送续火消息
7. 等待回调...               ←──  8. POST http://localhost:7788/done
9. 收到回调，关闭浏览器
10. 处理下一个账号 → 回到 3
```

## 文件说明

| 文件 | 说明 |
|---|---|
| `config.json` | 多账号配置文件 |
| `callback_server.py` | HTTP 回调监听器（Python 3，跨平台） |
| `scheduler.sh` | Linux / macOS 调度脚本 |
| `scheduler.ps1` | Windows 调度脚本 (PowerShell) |

## 依赖

| 依赖 | 用途 | 安装 |
|---|---|---|
| **Python 3** | 回调服务器 + 时间计算 | 各系统自行安装 |
| **jq** (仅 bash) | JSON 解析 | `apt install jq` / `brew install jq` |

## 快速开始

### 1. 准备浏览器 Profile

每个抖音账号需要一个**独立的浏览器 Profile**，用于隔离登录态和脚本配置。

#### Firefox

```bash
# 打开 Profile 管理器，创建新 Profile
firefox --ProfileManager

# Profile 默认路径：
# Linux:  ~/.mozilla/firefox/xxxxxxxx.profile-name
# macOS:  ~/Library/Application Support/Firefox/Profiles/xxxxxxxx.profile-name
# Windows: %APPDATA%\Mozilla\Firefox\Profiles\xxxxxxxx.profile-name
```

#### Chrome / Edge

Chrome/Edge 使用 `--user-data-dir` 参数，可以指定任意目录作为 Profile：

```bash
# 创建并使用新 Profile（首次启动时自动创建）
google-chrome --user-data-dir=/path/to/profile1

# Windows 示例
# "C:\Program Files\Google\Chrome\Application\chrome.exe" --user-data-dir="D:\chrome-profiles\account1"
```

### 2. 初始化每个 Profile

对每个 Profile，手动完成以下操作（**只需一次**）：

1. 使用该 Profile 启动浏览器
2. 安装 **Tampermonkey** 或 **ScriptCat**
3. 安装**脚本A**（抖音续火助手）
4. 访问 `https://creator.douyin.com/creator-micro/data/following/chat`
5. **登录抖音账号**
6. 在脚本A的设置面板中：
   - 配置续火目标用户、消息内容等
   - **启用「脚本B回调」**（`enableScriptBCallback = true`）
   - 确认回调端口与 `config.json` 中的 `callback_port` 一致（默认 `7788`）

### 3. 编辑 config.json

```jsonc
{
    "send_time": "00:01:00",         // 全局默认发送时间 (HH:MM:SS)
    "callback_port": 7788,           // 回调监听端口
    "timeout_seconds": 300,          // 单个账号最大等待时间(秒)
    "default_browser": "firefox",    // 默认浏览器: firefox / firefox-esr / chrome / edge
    "browser_paths": {               // 自定义浏览器路径（留空则自动检测）
        "firefox": "",
        "firefox-esr": "",
        "chrome": "",
        "edge": ""
    },
    "target_url": "https://creator.douyin.com/creator-micro/data/following/chat",
    "accounts": [
        {
            "name": "我的主号",
            "profile_path": "/home/user/.mozilla/firefox/abc123.main",
            "browser": "",           // 留空使用 default_browser，也可单独指定
            "send_time": "",         // 留空使用全局 send_time，也可单独指定如 "08:00:00"
            "enabled": true
        },
        {
            "name": "我的小号",
            "profile_path": "/home/user/.mozilla/firefox/def456.alt",
            "browser": "",
            "send_time": "12:30:00", // 该账号在 12:30 执行（覆盖全局时间）
            "enabled": true
        }
    ]
}
```

> **提示**：每个账号可设置独立的 `send_time`。留空或省略则使用全局 `send_time`。在 daemon 模式下，调度器会按各账号的 `send_time` 分别等待并依次执行。

### 4. 运行

#### Linux / macOS

```bash
# 赋予执行权限
chmod +x scheduler.sh

# 守护进程模式（按各账号 send_time 分别等待执行，每天循环）
./scheduler.sh

# 单次立即执行（测试用）
./scheduler.sh once
```

#### Windows (PowerShell)

```powershell
# 守护进程模式
.\scheduler.ps1

# 单次立即执行
.\scheduler.ps1 -Mode once
```

> **注意**：如果 PowerShell 提示执行策略限制，运行：
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
> ```

## 设为系统定时任务（可选）

如果不想用守护进程模式，也可以用系统定时任务在每天固定时间触发 `once` 模式：

### Linux (cron)

```bash
# crontab -e
1 0 * * * cd /path/to/shell && ./scheduler.sh once >> logs/cron.log 2>&1
```

### macOS (launchd)

创建 `~/Library/LaunchAgents/com.douyin.fire.plist`，设置每日触发。

### Windows (任务计划程序)

1. 打开「任务计划程序」
2. 创建基本任务 → 每日触发
3. 操作：启动程序
   - 程序：`powershell.exe`
   - 参数：`-ExecutionPolicy Bypass -File "D:\path\to\shell\scheduler.ps1" -Mode once`

## 日志

运行日志自动保存在 `shell/logs/` 目录下，按日期分文件。

## 浏览器路径参考

| 浏览器 | Windows | Linux | macOS |
|---|---|---|---|
| Firefox | `C:\Program Files\Mozilla Firefox\firefox.exe` | `firefox` | `/Applications/Firefox.app/Contents/MacOS/firefox` |
| Firefox ESR | `C:\Program Files\Mozilla Firefox ESR\firefox.exe` | `firefox-esr` | 同上 |
| Chrome | `C:\Program Files\Google\Chrome\Application\chrome.exe` | `google-chrome` | `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` |
| Edge | `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe` | `microsoft-edge` | `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge` |

## 故障排除

| 问题 | 解决方案 |
|---|---|
| 端口被占用 | 修改 `config.json` 中的 `callback_port`，同时在脚本A设置中修改端口 |
| 浏览器未找到 | 在 `config.json` 的 `browser_paths` 中填入完整路径 |
| Firefox 报 Profile 已锁定 | 确保同一 Profile 没有其他 Firefox 实例在运行 |
| 超时但脚本A未完成 | 增大 `timeout_seconds`；检查脚本A是否启用了回调 |
| Linux 无图形界面 | 安装 Xvfb：`apt install xvfb`，用 `xvfb-run ./scheduler.sh` 运行 |
