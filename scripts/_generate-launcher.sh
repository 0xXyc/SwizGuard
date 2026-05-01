#!/bin/bash
#
# _generate-launcher.sh
# Internal: writes the per-client connect launcher script.
# Called from add-client.sh (new client) and regen-client-configs.sh (existing
# client picks up upstream fixes on regen).
#
# Required environment:
#   CLIENT_NAME, CLIENT_DIR
#
# Output:
#   $CLIENT_DIR/connect-${CLIENT_NAME}.sh, chmod +x

set -euo pipefail

: "${CLIENT_NAME:?CLIENT_NAME required}"
: "${CLIENT_DIR:?CLIENT_DIR required}"

cat > "$CLIENT_DIR/connect-${CLIENT_NAME}.sh" <<LAUNCHEOF
#!/bin/bash
# SwizGuard client launcher for: ${CLIENT_NAME}
# Runs Xray in the background. No sudo needed unless you flip the system proxy.
#
# Usage: bash connect-${CLIENT_NAME}.sh [start|stop|status|where]
#        bash connect-${CLIENT_NAME}.sh enable-system-proxy
#        bash connect-${CLIENT_NAME}.sh disable-system-proxy

set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
PID_FILE="\$HOME/.swizguard-${CLIENT_NAME}.pid"
SOCKS_PORT=10808
HTTP_PORT=10809

_running() {
    [ -f "\$PID_FILE" ] && kill -0 "\$(cat \$PID_FILE)" 2>/dev/null
}

start() {
    if _running; then
        echo "[!] SwizGuard already running (PID \$(cat \$PID_FILE))"
        exit 1
    fi

    echo "[*] Starting SwizGuard (${CLIENT_NAME})..."
    xray run -config "\$SCRIPT_DIR/xray-client.json" > "\$SCRIPT_DIR/xray.log" 2>&1 &
    echo \$! > "\$PID_FILE"
    sleep 2

    if ! _running; then
        echo "[!] Xray failed to start. Check \$SCRIPT_DIR/xray.log"
        rm -f "\$PID_FILE"
        exit 1
    fi

    echo "[+] SwizGuard running (PID \$(cat \$PID_FILE))"
    echo ""
    echo "    SOCKS5 proxy: 127.0.0.1:\$SOCKS_PORT"
    echo "    HTTP proxy:   127.0.0.1:\$HTTP_PORT"
    echo ""
    echo "    Test:  curl --socks5 127.0.0.1:\$SOCKS_PORT ifconfig.me"
    echo ""
    echo "    For system-wide on macOS, run:"
    echo "      bash \$(basename "\$0") enable-system-proxy"
}

stop() {
    if [ ! -f "\$PID_FILE" ]; then
        echo "[!] SwizGuard not running"
        return
    fi
    echo "[*] Stopping SwizGuard..."
    kill "\$(cat \$PID_FILE)" 2>/dev/null || true
    rm -f "\$PID_FILE"
    echo "[+] SwizGuard stopped"
}

status() {
    if _running; then
        echo "[+] SwizGuard running (PID \$(cat \$PID_FILE))"
        echo "    SOCKS5: 127.0.0.1:\$SOCKS_PORT"
        echo "    HTTP:   127.0.0.1:\$HTTP_PORT"
    else
        echo "[-] SwizGuard not running"
    fi
}

# Resolve the macOS network service that owns the default route.
# Falls back to Wi-Fi if detection fails (e.g. only Wi-Fi exists, or odd setup).
_active_service() {
    local iface
    iface=\$(route -n get default 2>/dev/null | awk '/interface:/ {print \$2}')
    if [ -z "\$iface" ]; then
        echo "Wi-Fi"
        return
    fi
    local svc=""
    while IFS= read -r line; do
        case "\$line" in
            "("[0-9]*")"*) svc="\${line#*) }" ;;
            *"Device: \$iface)"*) echo "\$svc"; return ;;
        esac
    done < <(networksetup -listnetworkserviceorder)
    echo "Wi-Fi"
}

# Emit the names of every network service that currently has the SwizGuard
# SOCKS proxy set (server 127.0.0.1, port \$SOCKS_PORT). Used by
# disable_system_proxy to clean up after users who flipped networks while
# the proxy was active.
_services_with_swizguard() {
    local svc=""
    while IFS= read -r line; do
        case "\$line" in
            "("[0-9]*")"*) svc="\${line#*) }" ;;
            *"Device:"*)
                [ -z "\$svc" ] && continue
                local cur
                cur=\$(networksetup -getsocksfirewallproxy "\$svc" 2>/dev/null) || continue
                if echo "\$cur" | grep -q '^Server: 127.0.0.1\$' && \\
                   echo "\$cur" | grep -q "^Port: \$SOCKS_PORT\\\$"; then
                    echo "\$svc"
                fi
                svc=""
                ;;
        esac
    done < <(networksetup -listnetworkserviceorder)
}

enable_system_proxy() {
    if [[ "\$OSTYPE" != "darwin"* ]]; then
        echo "[!] System proxy auto-config only supported on macOS"
        exit 1
    fi
    if ! _running; then
        echo "[!] SwizGuard tunnel is not running."
        echo "    Enabling system proxy now would break internet because"
        echo "    traffic would be routed into a dead local proxy."
        echo "    Start the tunnel first:  bash \$(basename "\$0") start"
        exit 1
    fi
    local svc
    svc=\$(_active_service)
    echo "[*] Enabling system SOCKS + HTTP proxy on '\$svc'..."
    sudo networksetup -setsocksfirewallproxy "\$svc" 127.0.0.1 \$SOCKS_PORT
    sudo networksetup -setsocksfirewallproxystate "\$svc" on
    sudo networksetup -setwebproxy "\$svc" 127.0.0.1 \$HTTP_PORT
    sudo networksetup -setwebproxystate "\$svc" on
    sudo networksetup -setsecurewebproxy "\$svc" 127.0.0.1 \$HTTP_PORT
    sudo networksetup -setsecurewebproxystate "\$svc" on
    echo "[+] System proxy enabled on '\$svc'"
    echo "    All browser + most app traffic now routes through SwizGuard"
}

disable_system_proxy() {
    if [[ "\$OSTYPE" != "darwin"* ]]; then
        echo "[!] System proxy auto-config only supported on macOS"
        exit 1
    fi
    # Disable on every service that has SwizGuard set, not just the active one.
    # Handles users who flipped networks (e.g. enabled on Ethernet, then
    # switched to Wi-Fi) and would otherwise leave dangling proxy state.
    local found=0
    local svc
    while IFS= read -r svc; do
        [ -z "\$svc" ] && continue
        echo "[*] Disabling system proxy on '\$svc'..."
        sudo networksetup -setsocksfirewallproxystate "\$svc" off
        sudo networksetup -setwebproxystate "\$svc" off
        sudo networksetup -setsecurewebproxystate "\$svc" off
        found=1
    done < <(_services_with_swizguard)
    if [ "\$found" -eq 0 ]; then
        # No service had SwizGuard set, fall back to clearing the active one.
        svc=\$(_active_service)
        echo "[*] No SwizGuard proxy state found. Clearing '\$svc' anyway..."
        sudo networksetup -setsocksfirewallproxystate "\$svc" off
        sudo networksetup -setwebproxystate "\$svc" off
        sudo networksetup -setsecurewebproxystate "\$svc" off
    fi
    echo "[+] System proxy disabled"
}

where() {
    local iface active
    iface=\$(route -n get default 2>/dev/null | awk '/interface:/ {print \$2}' || true)
    active=\$(_active_service)
    echo "  Default route interface: \${iface:-<none>}"
    echo "  Default route service:   \$active"
    if _running; then
        echo "  SwizGuard tunnel:        running (PID \$(cat \$PID_FILE))"
    else
        echo "  SwizGuard tunnel:        stopped"
    fi
    echo "  Services with SwizGuard SOCKS proxy set:"
    local any=0
    while IFS= read -r svc; do
        [ -z "\$svc" ] && continue
        echo "    - \$svc"
        any=1
    done < <(_services_with_swizguard)
    if [ "\$any" -eq 0 ]; then
        echo "    (none)"
    fi
}

case "\${1:-start}" in
    start)                 start ;;
    stop)                  stop ;;
    status)                status ;;
    where)                 where ;;
    enable-system-proxy)   enable_system_proxy ;;
    disable-system-proxy)  disable_system_proxy ;;
    *)                     echo "Usage: \$0 [start|stop|status|where|enable-system-proxy|disable-system-proxy]" ;;
esac
LAUNCHEOF

chmod +x "$CLIENT_DIR/connect-${CLIENT_NAME}.sh"
