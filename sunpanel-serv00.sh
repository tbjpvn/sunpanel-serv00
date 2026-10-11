#!/usr/bin/env bash
# =====================================================================
#  Serv00 (FreeBSD) - Sun-Panel 安装 / 升级 / 守护 / 卸载 管理脚本
#
#  - 官方没有 FreeBSD 发布包，所以在本机用 Go + Node 从源码编译
#  - 默认安装 v1.3.0；v1.8.1 只在选择“升级”时才会下载编译
#  - 端口申请、域名绑定、cron 防杀守护，全部在脚本里交互完成，
#    不需要进 Serv00 面板操作（通过 devil 命令行完成）
#
#  用法：bash sunpanel-serv00.sh
# =====================================================================
set -u

APP_NAME="sun-panel"
APP_DIR="${SUNPANEL_DIR:-$HOME/apps/sun-panel}"   # 程序+数据目录
STATE_FILE="$HOME/apps/.sunpanel.env"             # 记录端口/域名/版本等
BUILD_DIR="$HOME/.sunpanel-build"                 # 临时编译目录
REPO_URL="https://github.com/hslr-s/sun-panel.git"
INSTALL_TAG="v1.3.0"                              # 默认安装版本
UPGRADE_TAG="v1.8.1"                              # 升级默认目标版本
CRON_MARK="# sun-panel-watchdog"

info() { echo "➜ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# 常见的用户级可执行目录
export PATH="$HOME/.npm-global/bin:/usr/local/bin:$PATH"

ask_yn() {  # ask_yn "提示(Y/n)" 默认值(y|n)
    local a
    read -r -p "$1 " a
    a="${a:-${2:-n}}"
    case "$a" in y|Y) return 0 ;; *) return 1 ;; esac
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "未找到命令: $1  ($2)"
}

have_devil() { command -v devil >/dev/null 2>&1; }

# ---------------------------------------------------------------------
# 状态文件
# ---------------------------------------------------------------------
load_state() {
    DOMAIN=""; PORT=""; TAG=""; PORT_AUTO=0; DOMAIN_ADDED=0; WD_INTERVAL=5
    # shellcheck disable=SC1090
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
    return 0
}

save_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
DOMAIN="$DOMAIN"
PORT="$PORT"
TAG="$TAG"
PORT_AUTO="$PORT_AUTO"
DOMAIN_ADDED="$DOMAIN_ADDED"
WD_INTERVAL="$WD_INTERVAL"
EOF
}

installed() { [ -x "$APP_DIR/sun-panel" ]; }

# ---------------------------------------------------------------------
# pm2 / 进程
# ---------------------------------------------------------------------
ensure_pm2() {
    command -v pm2 >/dev/null 2>&1 && return 0
    warn "未发现 pm2，尝试安装到 $HOME/.npm-global ..."
    mkdir -p "$HOME/.npm-global"
    npm install -g pm2 --prefix "$HOME/.npm-global" >/dev/null 2>&1
    export PATH="$HOME/.npm-global/bin:$PATH"
    command -v pm2 >/dev/null 2>&1 \
        || die "pm2 安装失败，请先手动安装: npm install -g pm2 --prefix ~/.npm-global"
    ok "pm2 安装完成"
}

pm2_start() {
    pm2 delete "$APP_NAME" >/dev/null 2>&1
    pm2 start "$APP_DIR/sun-panel" --name "$APP_NAME" --interpreter none --cwd "$APP_DIR" >/dev/null 2>&1 \
        || return 1
    pm2 save >/dev/null 2>&1
    return 0
}

http_code() {
    curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:$1/" 2>/dev/null
}

wait_up() {  # wait_up 端口 最长秒数
    local i=0 c
    while [ "$i" -lt "$2" ]; do
        c="$(http_code "$1")"
        case "$c" in ''|000) ;; *) return 0 ;; esac
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# ---------------------------------------------------------------------
# 端口 / 域名（devil）
# ---------------------------------------------------------------------
list_tcp_ports() {   # 输出账号已有的 TCP 端口（每行一个）
    have_devil || return 0
    local raw ports
    raw="$(devil port list 2>&1)"
    ports="$(echo "$raw" | grep -i 'tcp' | grep -oE '[0-9]{4,5}' | sort -un)"
    # 兜底：输出里没有 tcp 字样时，取所有 4-5 位数字
    [ -n "$ports" ] || ports="$(echo "$raw" | grep -oE '[0-9]{4,5}' | sort -un)"
    echo "$ports" | awk '$1>=1024 && $1<=65535'
}

port_in_use() {   # 端口是否已有本账号进程在监听
    command -v sockstat >/dev/null 2>&1 || return 1
    [ "$(sockstat -l -p "$1" 2>/dev/null | wc -l)" -gt 1 ]
}

choose_port() {
    local p out raw i sel marker first_free=""
    local -a ports=()
    echo
    if have_devil; then
        raw="$(devil port list 2>&1)"
        while IFS= read -r p; do
            [ -n "$p" ] && ports+=("$p")
        done < <(list_tcp_ports)
    else
        warn "未检测到 devil 命令（可能不是 Serv00），只能手动输入端口"
    fi

    PORT_AUTO=0
    if [ "${#ports[@]}" -gt 0 ]; then
        echo "检测到账号已有的 TCP 端口："
        i=1
        for p in "${ports[@]}"; do
            marker=""
            if port_in_use "$p"; then
                marker="  (已有进程占用)"
            elif [ -z "$first_free" ]; then
                first_free="$i"
            fi
            echo "  $i) $p$marker"
            i=$((i + 1))
        done
        echo "  a) 自动申请一个新端口"
        echo "  m) 手动输入端口号"
        read -r -p "请选择 [默认 ${first_free:-1}]: " sel
        sel="${sel:-${first_free:-1}}"
        case "$sel" in
            a|A) p="" ;;
            m|M) read -r -p "输入端口号: " p ;;
            *[!0-9]*) die "无效选择" ;;
            *)
                [ "$sel" -ge 1 ] && [ "$sel" -le "${#ports[@]}" ] || die "无效选择"
                p="${ports[$((sel - 1))]}"
                ;;
        esac
    else
        if have_devil; then
            echo "没有解析到已有端口，devil port list 的原始输出如下："
            echo "$raw" | sed 's/^/    /'
        fi
        read -r -p "输入 TCP 端口号；直接回车 = 自动申请新端口: " p
    fi

    if [ -z "$p" ]; then
        have_devil || die "没有 devil 命令，请手动输入端口号"
        out="$(devil port add tcp random 2>&1)"
        echo "$out" | sed 's/^/    /'
        p="$(echo "$out" | grep -oE '[0-9]{4,5}' | tail -n1)"
        [ -n "$p" ] || die "自动申请失败（3 个端口额度可能已满），请重新运行并选择一个已有端口"
        PORT_AUTO=1
        ok "已申请端口 $p"
    fi
    case "$p" in ''|*[!0-9]*) die "端口必须是数字" ;; esac
    [ "$p" -ge 1024 ] && [ "$p" -le 65535 ] || die "端口范围应为 1024-65535"
    PORT="$p"
    ok "使用端口 $PORT"
}

show_ip() {
    echo "服务器 IP（devil vhost list all）："
    if have_devil; then
        devil vhost list all 2>&1 | sed 's/^/    /'
    else
        echo "    未检测到 devil 命令，无法查询"
    fi
}

bind_domain() {   # 使用全局 DOMAIN / PORT
    have_devil || { warn "没有 devil 命令，请手动在面板把 $DOMAIN 设为 Proxy -> localhost:$PORT"; return 1; }
    if devil www list 2>/dev/null | awk '{print $1}' | grep -qixF "$DOMAIN"; then
        warn "$DOMAIN 在 Serv00 上已存在站点"
        if ask_yn "删除它并重建为 Proxy -> localhost:$PORT ？原站点内容会丢失 (y/N):" n; then
            devil www del "$DOMAIN" 2>&1 | sed 's/^/    /'
        else
            warn "已跳过域名绑定（可稍后用菜单“绑定域名”重试）"
            return 1
        fi
    fi
    if devil www add "$DOMAIN" proxy localhost "$PORT" 2>&1 | sed 's/^/    /'; then
        DOMAIN_ADDED=1
        ok "已绑定 $DOMAIN -> localhost:$PORT"
        echo "   提示：请把 $DOMAIN 的 DNS A 记录指向下面的 Serv00 IP"
        show_ip
        return 0
    fi
    return 1
}

ask_domain() {
    local d
    read -r -p "请输入要绑定的域名（如 nav.example.com；回车跳过，稍后再绑）: " d
    DOMAIN="$d"
}

# ---------------------------------------------------------------------
# cron 守护（防杀）
# ---------------------------------------------------------------------
write_watchdog() {
    local pm2_bin node_bin path_val
    pm2_bin="$(command -v pm2)"
    node_bin="$(command -v node)"
    path_val="$(dirname "$pm2_bin"):$(dirname "$node_bin"):/usr/local/bin:/usr/bin:/bin"
    cat > "$APP_DIR/watchdog.sh" <<'EOF'
#!/bin/sh
PATH="@@PATH@@"; export PATH
APP_DIR="@@APP_DIR@@"
PORT="@@PORT@@"
PM2="@@PM2@@"
LOG="$APP_DIR/watchdog.log"

[ -f "$APP_DIR/.upgrading" ] && exit 0

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
code() { curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null; }
alive() { c="$(code)"; [ -n "$c" ] && [ "$c" != "000" ]; }

# 日志过大时截断
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 102400 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

alive && exit 0

log "端口 $PORT 无响应，尝试 pm2 resurrect"
"$PM2" resurrect >/dev/null 2>&1
sleep 6
alive && { log "resurrect 恢复成功"; exit 0; }

log "resurrect 无效，重新创建 pm2 进程"
"$PM2" delete sun-panel >/dev/null 2>&1
"$PM2" start "$APP_DIR/sun-panel" --name sun-panel --interpreter none --cwd "$APP_DIR" >/dev/null 2>&1
"$PM2" save >/dev/null 2>&1
sleep 6
if alive; then log "重建成功"; else log "重建后仍无响应，请手动检查"; fi
EOF
    sed -e "s|@@PATH@@|$path_val|" \
        -e "s|@@APP_DIR@@|$APP_DIR|" \
        -e "s|@@PORT@@|$PORT|" \
        -e "s|@@PM2@@|$pm2_bin|" \
        "$APP_DIR/watchdog.sh" > "$APP_DIR/watchdog.sh.tmp" \
        && mv "$APP_DIR/watchdog.sh.tmp" "$APP_DIR/watchdog.sh"
    chmod +x "$APP_DIR/watchdog.sh"
}

cron_remove() {
    command -v crontab >/dev/null 2>&1 || return 0
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -vF "$CRON_MARK" > "$tmp"
    crontab "$tmp" 2>/dev/null
    rm -f "$tmp"
}

cron_enable() {   # 使用全局 WD_INTERVAL
    command -v crontab >/dev/null 2>&1 \
        || { warn "没有 crontab 命令，无法自动添加守护"; return 1; }
    write_watchdog
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -vF "$CRON_MARK" > "$tmp"
    echo "*/$WD_INTERVAL * * * * /bin/sh $APP_DIR/watchdog.sh >/dev/null 2>&1 $CRON_MARK" >> "$tmp"
    echo "@reboot /bin/sh $APP_DIR/watchdog.sh >/dev/null 2>&1 $CRON_MARK" >> "$tmp"
    if crontab "$tmp" 2>/dev/null; then
        ok "守护已开启：每 $WD_INTERVAL 分钟检测一次 + 开机自启"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    warn "写入 crontab 失败。可手动添加这两行："
    echo "   */$WD_INTERVAL * * * * /bin/sh $APP_DIR/watchdog.sh >/dev/null 2>&1"
    echo "   @reboot /bin/sh $APP_DIR/watchdog.sh >/dev/null 2>&1"
    return 1
}

cron_enabled() {
    crontab -l 2>/dev/null | grep -qF "$CRON_MARK"
}

ask_interval() {
    local v
    read -r -p "守护检测间隔（分钟，1-59）[${WD_INTERVAL}]: " v
    v="${v:-$WD_INTERVAL}"
    case "$v" in ''|*[!0-9]*) die "间隔必须是数字" ;; esac
    [ "$v" -ge 1 ] && [ "$v" -le 59 ] || die "间隔范围应为 1-59"
    WD_INTERVAL="$v"
}

# ---------------------------------------------------------------------
# 编译指定版本 -> $BUILD_DIR/sun-panel.bin 和 $BUILD_DIR/web
# ---------------------------------------------------------------------
build_version() {
    local tag="$1" gomain pkg go_dir front_dir
    need_cmd git  "Serv00 默认自带，若缺失请联系支持"
    need_cmd go   "Serv00 默认自带 Go"
    need_cmd node "需要 Node.js 来编译前端"
    need_cmd npm  "需要 npm 来编译前端"

    info "拉取源码 $tag ..."
    rm -rf "$BUILD_DIR"
    git clone --depth 1 --branch "$tag" "$REPO_URL" "$BUILD_DIR/src" \
        || die "克隆失败：tag 不存在或网络不通"
    cd "$BUILD_DIR/src" || die "无法进入编译目录"

    gomain="$(find . -name main.go -not -path '*/node_modules/*' | head -n1)"
    [ -n "$gomain" ] || die "$tag 的源码中没找到 main.go（源码可能不完整），未做任何改动"
    go_dir="$(dirname "$gomain")"
    if [ -f ./package.json ]; then
        pkg="./package.json"
    else
        pkg="$(find . -maxdepth 2 -name package.json -not -path '*/node_modules/*' | head -n1)"
    fi
    [ -n "$pkg" ] || die "$tag 的源码中没找到前端 package.json（源码可能不完整），未做任何改动"
    front_dir="$(dirname "$pkg")"
    info "后端目录: $go_dir   前端目录: $front_dir"

    info "编译前端（可能需要几分钟）..."
    ( cd "$front_dir" && npm install --no-audit --no-fund && npm run build ) \
        || die "前端编译失败（常见原因：内存/进程数受限、Node 版本过低），未做任何改动"
    [ -f "$front_dir/dist/index.html" ] || die "前端产物 dist/index.html 不存在，未做任何改动"

    info "编译后端 ..."
    command -v cc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 \
        || die "没有 C 编译器（sqlite 需要 CGO），无法编译后端"
    export GOPATH="$HOME/.cache/gopath" GOCACHE="$HOME/.cache/gobuild" CGO_ENABLED=1
    export PATH="$GOPATH/bin:$PATH"

    # 官方构建流程会用 go-bindata 生成 assets/bindata.go（仓库里没有这个文件）
    if grep -qs 'go-bindata' Dockerfile build.sh 2>/dev/null && [ ! -f "$go_dir/assets/bindata.go" ]; then
        info "生成内置资源 assets/bindata.go（go-bindata）..."
        ( cd "$HOME" \
            && go install github.com/go-bindata/go-bindata/...@latest \
            && go install github.com/elazarl/go-bindata-assetfs/...@latest ) \
            || die "go-bindata 安装失败（网络或 Go 版本问题），未做任何改动"
        ( cd "$go_dir" && go-bindata-assetfs -o=assets/bindata.go -pkg=assets assets/... ) \
            || die "生成 bindata.go 失败，未做任何改动"
    fi

    ( cd "$go_dir" && go build -o "$BUILD_DIR/sun-panel.bin" \
        -ldflags "-X sun-panel/global.RUNCODE=release" . ) \
        || die "Go 编译失败（上面是具体报错），未做任何改动"

    rm -rf "$BUILD_DIR/web"
    cp -R "$front_dir/dist" "$BUILD_DIR/web"
    cd "$HOME" || true
    ok "$tag 编译完成"
}

write_port_conf() {   # 在 APP_DIR 下，把 PORT 写进 conf/conf.ini
    local tmp
    cd "$APP_DIR" || die "无法进入 $APP_DIR"
    if [ ! -f conf/conf.ini ]; then
        info "生成默认配置 ..."
        timeout 15 ./sun-panel -config >/dev/null 2>&1
    fi
    [ -f conf/conf.ini ] || die "未生成 conf/conf.ini，请手动运行 ./sun-panel -config 查看输出"
    tmp="$(mktemp)"
    sed -E "s/^[[:space:]]*http_port[[:space:]]*=.*/http_port=$PORT/" conf/conf.ini > "$tmp"
    if grep -q "^http_port=$PORT" "$tmp"; then
        mv "$tmp" conf/conf.ini
        ok "已写入端口 $PORT"
    else
        rm -f "$tmp"
        echo "---- 当前 conf/conf.ini ----"; cat conf/conf.ini; echo "----------------------------"
        die "配置里没有找到 http_port 项，请手动编辑 $APP_DIR/conf/conf.ini 后执行 pm2 restart $APP_NAME"
    fi
}

backup_data() {   # 备份 conf/database/uploads，输出文件路径到 BACKUP_FILE
    local files="" d
    BACKUP_FILE=""
    for d in conf database uploads; do
        [ -e "$APP_DIR/$d" ] && files="$files $d"
    done
    [ -n "$files" ] || return 0
    BACKUP_FILE="$HOME/sun-panel-backup-$(date +%Y%m%d%H%M%S).tar.gz"
    # shellcheck disable=SC2086
    tar -czf "$BACKUP_FILE" -C "$APP_DIR" $files && ok "数据已备份: $BACKUP_FILE" \
        || { warn "备份失败"; BACKUP_FILE=""; return 1; }
}

# ---------------------------------------------------------------------
# 1. 安装
# ---------------------------------------------------------------------
do_install() {
    echo "------------- 安装 Sun-Panel $INSTALL_TAG -------------"
    load_state
    if installed; then
        warn "检测到已安装（版本 ${TAG:-未知}）。要换版本请用“升级”，要重装请先“卸载”。"
        return 0
    fi
    need_cmd git  "Serv00 默认自带"
    need_cmd go   "Serv00 默认自带"
    need_cmd node "需要 Node.js"
    need_cmd npm  "需要 npm"
    need_cmd curl "用于健康检测"
    ensure_pm2

    choose_port
    ask_domain
    ask_interval
    local want_wd=1
    ask_yn "是否开启 cron 守护（被杀进程会自动拉起）(Y/n):" y || want_wd=0

    build_version "$INSTALL_TAG"

    info "部署到 $APP_DIR ..."
    mkdir -p "$APP_DIR"
    cp "$BUILD_DIR/sun-panel.bin" "$APP_DIR/sun-panel" && chmod +x "$APP_DIR/sun-panel"
    rm -rf "$APP_DIR/web"
    cp -R "$BUILD_DIR/web" "$APP_DIR/web"

    write_port_conf
    TAG="$INSTALL_TAG"
    save_state

    pm2_start || die "pm2 启动失败"
    if wait_up "$PORT" 20; then
        ok "服务已在本地端口 $PORT 响应"
    else
        warn "20 秒内本地端口没有响应，请用菜单“查看状态”或 pm2 logs $APP_NAME 排查"
    fi

    if [ -n "$DOMAIN" ]; then
        bind_domain
        save_state
    fi

    if [ "$want_wd" -eq 1 ]; then
        cron_enable
    fi
    save_state
    rm -rf "$BUILD_DIR"

    echo "=============================================="
    ok "安装完成（版本 $TAG）"
    [ -n "$DOMAIN" ] && echo "访问地址: http://$DOMAIN"
    [ -z "$DOMAIN" ] && echo "还没绑定域名：用菜单“绑定域名”即可，无需进面板"
    show_ip
    echo "默认账号: admin@sun.cc   默认密码: 12345678   —— 登录后请立刻修改"
    echo "=============================================="
}

# ---------------------------------------------------------------------
# 2. 升级（失败自动回滚）
# ---------------------------------------------------------------------
do_upgrade() {
    echo "------------- 升级 Sun-Panel -------------"
    load_state
    installed || { warn "尚未安装，请先选择“安装”"; return 0; }
    ensure_pm2
    need_cmd curl "用于健康检测"

    local target
    echo "当前版本: ${TAG:-未知}"
    read -r -p "升级到哪个版本 tag [$UPGRADE_TAG]: " target
    target="${target:-$UPGRADE_TAG}"
    [ "$target" != "$TAG" ] || { warn "已经是 $target，无需升级"; return 0; }

    warn "升级会先备份数据；新版本编译成功才会替换，启动失败会自动回滚。"
    ask_yn "继续? (y/N):" n || { echo "已取消"; return 0; }

    backup_data

    build_version "$target"

    touch "$APP_DIR/.upgrading"
    trap 'rm -f "$APP_DIR/.upgrading"' EXIT

    info "替换程序文件 ..."
    pm2 delete "$APP_NAME" >/dev/null 2>&1
    rm -rf "$APP_DIR/sun-panel.old" "$APP_DIR/web.old"
    mv "$APP_DIR/sun-panel" "$APP_DIR/sun-panel.old"
    [ -d "$APP_DIR/web" ] && mv "$APP_DIR/web" "$APP_DIR/web.old"
    cp "$BUILD_DIR/sun-panel.bin" "$APP_DIR/sun-panel" && chmod +x "$APP_DIR/sun-panel"
    cp -R "$BUILD_DIR/web" "$APP_DIR/web"

    pm2_start
    if wait_up "$PORT" 25; then
        rm -rf "$APP_DIR/sun-panel.old" "$APP_DIR/web.old"
        TAG="$target"
        save_state
        rm -rf "$BUILD_DIR"
        ok "升级成功，当前版本 $TAG"
    else
        warn "新版本启动后没有响应，正在回滚到 ${TAG:-旧版本} ..."
        pm2 delete "$APP_NAME" >/dev/null 2>&1
        rm -rf "$APP_DIR/sun-panel" "$APP_DIR/web"
        mv "$APP_DIR/sun-panel.old" "$APP_DIR/sun-panel"
        [ -d "$APP_DIR/web.old" ] && mv "$APP_DIR/web.old" "$APP_DIR/web"
        pm2_start
        if wait_up "$PORT" 20; then
            ok "已回滚，旧版本恢复运行"
        else
            warn "回滚后仍无响应，请手动检查；数据备份: ${BACKUP_FILE:-无}"
        fi
        rm -rf "$BUILD_DIR"
        return 1
    fi
}

# ---------------------------------------------------------------------
# 3. 卸载
# ---------------------------------------------------------------------
do_uninstall() {
    echo "------------- 卸载 Sun-Panel -------------"
    load_state
    echo "将执行："
    echo "  - 停止并删除 pm2 进程 $APP_NAME"
    echo "  - 移除 cron 守护与开机自启"
    echo "  - 删除目录 $APP_DIR"
    ask_yn "确认卸载? (y/N):" n || { echo "已取消"; return 0; }

    if [ -d "$APP_DIR" ] && ask_yn "卸载前备份 conf/database/uploads 到 ~ 目录? (Y/n):" y; then
        backup_data
    fi

    if command -v pm2 >/dev/null 2>&1; then
        pm2 delete "$APP_NAME" >/dev/null 2>&1
        pm2 save >/dev/null 2>&1
    fi
    cron_remove
    rm -rf "$APP_DIR" "$BUILD_DIR"
    ok "本地进程、守护、文件已清理"

    if have_devil; then
        if [ -n "$DOMAIN" ]; then
            if [ "$DOMAIN_ADDED" = "1" ]; then
                ask_yn "同时删除 Serv00 上的站点 $DOMAIN ? (y/N):" n \
                    && devil www del "$DOMAIN" 2>&1 | sed 's/^/    /'
            else
                echo "域名 $DOMAIN 不是本脚本创建的，未处理；需要的话手动: devil www del $DOMAIN"
            fi
        fi
        if [ -n "$PORT" ]; then
            if [ "$PORT_AUTO" = "1" ]; then
                ask_yn "同时释放脚本申请的端口 $PORT ? (y/N):" n \
                    && devil port del tcp "$PORT" 2>&1 | sed 's/^/    /'
            else
                echo "端口 $PORT 不是本脚本申请的，未处理；需要的话手动: devil port del tcp $PORT"
            fi
        fi
    else
        [ -n "$DOMAIN" ] && echo "请手动清理站点: $DOMAIN"
        [ -n "$PORT" ]   && echo "请手动释放端口: $PORT"
    fi
    rm -f "$STATE_FILE"
    ok "卸载完成"
}

# ---------------------------------------------------------------------
# 4-6. 状态 / 重启 / 重置密码
# ---------------------------------------------------------------------
do_status() {
    local code
    load_state
    echo "版本: ${TAG:-未安装}    端口: ${PORT:-?}    域名: ${DOMAIN:-未绑定}"
    if command -v pm2 >/dev/null 2>&1; then
        pm2 describe "$APP_NAME" 2>/dev/null | grep -E 'status|uptime|restarts' \
            || warn "pm2 中没有 $APP_NAME 进程"
    else
        warn "未安装 pm2"
    fi
    if [ -n "$PORT" ]; then
        code="$(http_code "$PORT")"
        echo "本地端口 $PORT 响应状态码: ${code:-无响应}"
    fi
    if cron_enabled; then
        echo "cron 守护: 已开启（每 ${WD_INTERVAL} 分钟）"
        [ -f "$APP_DIR/watchdog.log" ] && { echo "最近守护日志:"; tail -n 5 "$APP_DIR/watchdog.log" | sed 's/^/    /'; }
    else
        echo "cron 守护: 未开启"
    fi
}

do_restart() {
    load_state
    command -v pm2 >/dev/null 2>&1 || { warn "未安装 pm2"; return 0; }
    installed || { warn "尚未安装"; return 0; }
    if pm2 restart "$APP_NAME" >/dev/null 2>&1; then
        ok "已重启"
    else
        pm2_start && ok "进程不存在，已重新创建并启动" || warn "启动失败"
    fi
}

do_reset_pw() {
    installed || { warn "尚未安装"; return 0; }
    ( cd "$APP_DIR" && ./sun-panel -password-reset )
}

# ---------------------------------------------------------------------
# 7. 守护管理
# ---------------------------------------------------------------------
do_watchdog() {
    load_state
    installed || { warn "尚未安装"; return 0; }
    ensure_pm2
    echo "当前: $(cron_enabled && echo "已开启（每 ${WD_INTERVAL} 分钟）" || echo 未开启)"
    echo "  1) 开启 / 修改间隔"
    echo "  2) 关闭守护"
    echo "  3) 立即检测一次"
    echo "  4) 查看守护日志"
    read -r -p "请选择 [1-4]: " c
    case "$c" in
        1) ask_interval; save_state; cron_enable ;;
        2) cron_remove; ok "守护已关闭" ;;
        3) write_watchdog; /bin/sh "$APP_DIR/watchdog.sh"; ok "已执行，状态见“查看状态”" ;;
        4) [ -f "$APP_DIR/watchdog.log" ] && tail -n 30 "$APP_DIR/watchdog.log" || echo "暂无日志（没触发过重启）" ;;
        *) warn "无效选项" ;;
    esac
}

# ---------------------------------------------------------------------
# 8. 绑定 / 更换域名
# ---------------------------------------------------------------------
do_domain() {
    load_state
    installed || { warn "尚未安装"; return 0; }
    [ -n "$PORT" ] || die "状态文件里没有端口信息"
    echo "当前域名: ${DOMAIN:-未绑定}    端口: $PORT"
    ask_domain
    [ -n "$DOMAIN" ] || { echo "已取消"; return 0; }
    bind_domain
    save_state
}

# ---------------------------------------------------------------------
# 菜单
# ---------------------------------------------------------------------
while true; do
    echo
    echo "=========================================="
    echo "     Serv00 - Sun-Panel 管理脚本"
    echo "=========================================="
    echo "  1) 安装（默认 $INSTALL_TAG）"
    echo "  2) 升级（默认目标 $UPGRADE_TAG，失败自动回滚）"
    echo "  3) 卸载"
    echo "  4) 查看状态"
    echo "  5) 重启服务"
    echo "  6) 重置管理员密码"
    echo "  7) cron 守护（防杀）管理"
    echo "  8) 绑定 / 更换域名"
    echo "  9) 查看服务器 IP"
    echo "  0) 退出"
    read -r -p "请选择 [0-9]: " choice
    case "$choice" in
        1) ( do_install ) ;;
        2) ( do_upgrade ) ;;
        3) ( do_uninstall ) ;;
        4) ( do_status ) ;;
        5) ( do_restart ) ;;
        6) ( do_reset_pw ) ;;
        7) ( do_watchdog ) ;;
        8) ( do_domain ) ;;
        9) ( show_ip ) ;;
        0) echo "Bye."; exit 0 ;;
        *) warn "无效选项" ;;
    esac
done
