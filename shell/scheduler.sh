#!/usr/bin/env bash
# ============================================================
# 抖音续火助手 - 调度脚本B (Linux / macOS)
#
# 用法:
#   ./scheduler.sh          # 守护进程模式，等待到配置时间后执行
#   ./scheduler.sh once     # 立即执行一次
#
# 依赖: jq, python3
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/scheduler_$(date +%Y%m%d).log"

# ---- 全局 PID（便于信号清理） ----
BROWSER_PID=""
SERVER_PID=""

cleanup() {
    log "收到退出信号，正在清理..."
    [[ -n "$SERVER_PID"  ]] && kill "$SERVER_PID"  2>/dev/null || true
    [[ -n "$BROWSER_PID" ]] && kill "$BROWSER_PID" 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

# ---- 日志 ----
mkdir -p "$LOG_DIR"

log()         { local m="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo -e "$m"; echo "$m" >> "$LOG_FILE"; }
log_success() { log "✓ $1"; }
log_error()   { log "✗ $1"; }
log_warn()    { log "⚠ $1"; }

# ---- 依赖检查 ----
check_deps() {
    local missing=()
    for cmd in jq python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少依赖: ${missing[*]}"
        log "  Ubuntu/Debian : sudo apt install ${missing[*]}"
        log "  macOS         : brew install ${missing[*]}"
        exit 1
    fi
}

# ---- JSON 读取 ----
cfg() { jq -r "$1" "$CONFIG_FILE"; }

# ---- 浏览器路径检测 ----
detect_browser() {
    local browser="$1"

    # 优先使用 config 中的自定义路径
    local custom
    custom=$(cfg ".browser_paths.\"${browser}\" // empty" 2>/dev/null || echo "")
    if [[ -n "$custom" ]] && [[ -x "$custom" || -e "$custom" ]]; then
        echo "$custom"; return
    fi

    local candidates=()
    case "$browser" in
        firefox)
            candidates=("firefox" "/Applications/Firefox.app/Contents/MacOS/firefox" "/snap/bin/firefox");;
        firefox-esr)
            candidates=("firefox-esr" "firefox" "/Applications/Firefox.app/Contents/MacOS/firefox");;
        chrome)
            candidates=("google-chrome" "google-chrome-stable" "chromium" "chromium-browser"
                        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome");;
        edge)
            candidates=("microsoft-edge" "microsoft-edge-stable"
                        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge");;
        *) echo ""; return;;
    esac

    for p in "${candidates[@]}"; do
        if command -v "$p" &>/dev/null; then command -v "$p"; return; fi
        if [[ -x "$p" ]]; then echo "$p"; return; fi
    done
    echo ""
}

# ---- 启动浏览器 ----
launch_browser() {
    local browser="$1" profile="$2" url="$3"
    local bin
    bin=$(detect_browser "$browser")

    if [[ -z "$bin" ]]; then
        log_error "未找到 ${browser}，请在 config.json 的 browser_paths 中指定路径"
        return 1
    fi
    log "启动浏览器: ${bin}"

    case "$browser" in
        firefox|firefox-esr)
            "$bin" --profile "$profile" --no-remote "$url" &;;
        chrome|edge)
            "$bin" --user-data-dir="$profile" --no-first-run "$url" &;;
    esac
    BROWSER_PID=$!
    echo "$BROWSER_PID"
}

# ---- 等待到指定时间（跨平台 date 兼容） ----
wait_until() {
    local send_time="$1"
    local wait_seconds
    wait_seconds=$(python3 -c "
import datetime
h, m, s = [int(x) for x in '${send_time}'.split(':')[:3]]
now = datetime.datetime.now()
target = now.replace(hour=h, minute=m, second=s, microsecond=0)
if target <= now:
    target += datetime.timedelta(days=1)
print(int((target - now).total_seconds()))
")
    local hrs=$((wait_seconds / 3600))
    local mins=$(((wait_seconds % 3600) / 60))
    log "距离下次发送 (${send_time}) 还有 ${hrs}小时${mins}分钟"
    sleep "$wait_seconds"
}

# ---- 处理单个账号 ----
process_account() {
    local name="$1" profile="$2" browser="$3" port="$4" timeout="$5" url="$6"

    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "处理账号: ${name}"
    log "浏览器: ${browser} | Profile: ${profile}"

    if [[ ! -d "$profile" ]]; then
        log_warn "Profile 目录不存在: ${profile}（首次运行时浏览器会自动创建）"
    fi

    # 启动回调服务器
    python3 "${SCRIPT_DIR}/callback_server.py" "$port" "$timeout" &
    SERVER_PID=$!
    sleep 1

    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        log_error "回调服务器启动失败（端口 ${port} 可能被占用）"
        SERVER_PID=""
        return 1
    fi
    log "回调服务器已启动 (端口: ${port}, PID: ${SERVER_PID})"

    # 启动浏览器
    local pid
    pid=$(launch_browser "$browser" "$profile" "$url") || { kill "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; return 1; }
    log "浏览器已启动 (PID: ${pid})"
    log "等待脚本A完成 (超时: ${timeout}秒)..."

    # 等待回调
    local result=0
    wait "$SERVER_PID" 2>/dev/null || result=$?
    SERVER_PID=""

    if [[ "$result" -eq 0 ]]; then
        log_success "账号 ${name} 任务完成"
    else
        log_error "账号 ${name} 超时或失败 (退出码: ${result})"
    fi

    # 关闭浏览器
    log "正在关闭浏览器 (PID: ${pid})..."
    kill "$pid" 2>/dev/null || true
    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "浏览器未正常关闭，强制终止"
        kill -9 "$pid" 2>/dev/null || true
    fi
    BROWSER_PID=""

    return "$result"
}

# ============================================================
# 主流程
# ============================================================
main() {
    local mode="${1:-daemon}"

    check_deps

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在: ${CONFIG_FILE}"
        log "请先编辑 config.json"
        exit 1
    fi

    log "═══════════════════════════════════════"
    log " 抖音续火助手 - 调度脚本B"
    log " 模式: $( [[ "$mode" == "daemon" ]] && echo "守护进程" || echo "单次执行" )"
    log "═══════════════════════════════════════"

    local send_time port timeout default_browser url account_count
    send_time=$(cfg '.send_time')
    port=$(cfg '.callback_port')
    timeout=$(cfg '.timeout_seconds')
    default_browser=$(cfg '.default_browser')
    url=$(cfg '.target_url')
    account_count=$(cfg '.accounts | length')

    log "发送时间: ${send_time} | 端口: ${port} | 超时: ${timeout}秒"
    log "默认浏览器: ${default_browser} | 账号数: ${account_count}"

    while true; do
        [[ "$mode" == "daemon" ]] && wait_until "$send_time"

        log ""
        log "═══════════════════════════════════════"
        log " 开始执行 $(date '+%Y-%m-%d %H:%M:%S')"
        log "═══════════════════════════════════════"

        local success=0 fail=0

        for ((i = 0; i < account_count; i++)); do
            local name profile browser enabled
            name=$(cfg ".accounts[$i].name")
            profile=$(cfg ".accounts[$i].profile_path")
            browser=$(cfg ".accounts[$i].browser // empty")
            enabled=$(cfg ".accounts[$i].enabled")

            [[ -z "$browser" || "$browser" == "null" ]] && browser="$default_browser"

            if [[ "$enabled" != "true" ]]; then
                log "跳过已禁用账号: ${name}"
                continue
            fi

            if process_account "$name" "$profile" "$browser" "$port" "$timeout" "$url"; then
                ((success++)) || true
            else
                ((fail++)) || true
            fi

            # 账号间间隔
            if [[ $i -lt $((account_count - 1)) ]]; then
                log "等待 5 秒后处理下一个账号..."
                sleep 5
            fi
        done

        log ""
        log "═══════════════════════════════════════"
        log " 任务完成: 成功=${success}  失败=${fail}"
        log "═══════════════════════════════════════"

        [[ "$mode" != "daemon" ]] && break

        # 防止同一分钟内重复触发
        sleep 61
    done
}

main "$@"
