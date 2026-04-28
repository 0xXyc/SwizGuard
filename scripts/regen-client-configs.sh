#!/bin/bash
#
# regen-client-configs.sh
# Regenerates xray-client.json and singbox-client.json for an existing client.
# Called by `swizguard regen` — reuses existing WG keys and tunnel IPs.
#
# Environment variables expected (sourced from credentials.env + client dir):
#   CLIENT_NAME, CLIENT_IPV4, CLIENT_IPV6, CLIENT_WG_PRIVKEY, CLIENT_DIR
#   SERVER_IP, XRAY_PORT, WG_PORT, CLIENT_UUID, CAMOUFLAGE_DEST
#   REALITY_PUBLIC_KEY, SERVER_WG_PUBLIC_KEY

set -euo pipefail

: "${CLIENT_NAME:?CLIENT_NAME required}"
: "${CLIENT_IPV4:?CLIENT_IPV4 required}"
: "${CLIENT_IPV6:?CLIENT_IPV6 required}"
: "${CLIENT_WG_PRIVKEY:?CLIENT_WG_PRIVKEY required}"
: "${CLIENT_DIR:?CLIENT_DIR required}"
: "${SERVER_IP:?SERVER_IP required}"
: "${XRAY_PORT:?XRAY_PORT required}"
: "${WG_PORT:?WG_PORT required}"
: "${CLIENT_UUID:?CLIENT_UUID required}"
: "${CAMOUFLAGE_DEST:?CAMOUFLAGE_DEST required}"
: "${REALITY_PUBLIC_KEY:?REALITY_PUBLIC_KEY required}"
: "${SERVER_WG_PUBLIC_KEY:?SERVER_WG_PUBLIC_KEY required}"

# ─── Xray client config ──────────────────────────────────────────
cat > "$CLIENT_DIR/xray-client.json" <<XCEOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": 10808,
            "protocol": "socks",
            "settings": {
                "udp": true,
                "auth": "noauth"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        },
        {
            "tag": "http-in",
            "listen": "127.0.0.1",
            "port": 10809,
            "protocol": "http"
        }
    ],
    "outbounds": [
        {
            "tag": "wireguard-out",
            "protocol": "wireguard",
            "settings": {
                "secretKey": "${CLIENT_WG_PRIVKEY}",
                "address": ["${CLIENT_IPV4}/32", "${CLIENT_IPV6}/128"],
                "peers": [
                    {
                        "publicKey": "${SERVER_WG_PUBLIC_KEY}",
                        "endpoint": "127.0.0.1:${WG_PORT}",
                        "allowedIPs": ["0.0.0.0/0", "::/0"],
                        "keepAlive": 25
                    }
                ],
                "mtu": 1280,
                "noKernelTun": true
            },
            "streamSettings": {
                "sockopt": {
                    "dialerProxy": "proxy"
                }
            }
        },
        {
            "tag": "proxy",
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "${SERVER_IP}",
                        "port": ${XRAY_PORT},
                        "users": [
                            {
                                "id": "${CLIENT_UUID}",
                                "encryption": "none",
                                "flow": "xtls-rprx-vision"
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "fingerprint": "chrome",
                    "serverName": "${CAMOUFLAGE_DEST}",
                    "publicKey": "${REALITY_PUBLIC_KEY}",
                    "shortId": "${SHORT_ID:-}",
                    "spiderX": ""
                }
            }
        },
        {
            "tag": "direct",
            "protocol": "freedom"
        }
    ],
    "routing": {
        "rules": [
            {
                "type": "field",
                "inboundTag": ["socks-in", "http-in"],
                "outboundTag": "wireguard-out"
            }
        ]
    }
}
XCEOF

# ─── Sing-box client config ──────────────────────────────────────
cat > "$CLIENT_DIR/singbox-client.json" <<SBEOF
{
    "log": {
        "level": "warning",
        "timestamp": true
    },
    "dns": {
        "servers": [
            {
                "tag": "dns-remote",
                "address": "https://1.1.1.1/dns-query",
                "detour": "proxy"
            },
            {
                "tag": "dns-direct",
                "address": "1.1.1.1",
                "detour": "direct"
            }
        ],
        "rules": [
            {
                "outbound": "any",
                "server": "dns-direct"
            }
        ],
        "strategy": "prefer_ipv4"
    },
    "inbounds": [
        {
            "type": "tun",
            "tag": "tun-in",
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "mtu": 9000,
            "auto_route": true,
            "stack": "system",
            "sniff": true,
            "platform": {
                "http_proxy": {
                    "enabled": false
                }
            }
        }
    ],
    "outbounds": [
        {
            "type": "vless",
            "tag": "proxy",
            "server": "${SERVER_IP}",
            "server_port": ${XRAY_PORT},
            "uuid": "${CLIENT_UUID}",
            "flow": "xtls-rprx-vision",
            "network": "tcp",
            "packet_encoding": "xudp",
            "tls": {
                "enabled": true,
                "server_name": "${CAMOUFLAGE_DEST}",
                "utls": {
                    "enabled": true,
                    "fingerprint": "chrome"
                },
                "reality": {
                    "enabled": true,
                    "public_key": "${REALITY_PUBLIC_KEY}",
                    "short_id": "${SHORT_ID:-}"
                }
            }
        },
        {
            "type": "direct",
            "tag": "direct"
        }
    ],
    "endpoints": [
        {
            "type": "wireguard",
            "tag": "wg-out",
            "system": false,
            "mtu": 1280,
            "address": ["${CLIENT_IPV4}/32", "${CLIENT_IPV6}/128"],
            "private_key": "${CLIENT_WG_PRIVKEY}",
            "peers": [
                {
                    "address": "127.0.0.1",
                    "port": ${WG_PORT},
                    "public_key": "${SERVER_WG_PUBLIC_KEY}",
                    "allowed_ips": ["0.0.0.0/0", "::/0"],
                    "persistent_keepalive_interval": 25
                }
            ],
            "detour": "proxy"
        }
    ],
    "route": {
        "rules": [
            {
                "action": "sniff"
            },
            {
                "protocol": "dns",
                "action": "hijack-dns"
            },
            {
                "ip_is_private": true,
                "outbound": "direct"
            },
            {
                "inbound": "tun-in",
                "outbound": "wg-out"
            }
        ],
        "final": "wg-out",
        "auto_detect_interface": true
    }
}
SBEOF

# Defensive: ensure private.key is always 600 even if previously loosened.
[ -f "$CLIENT_DIR/private.key" ] && chmod 600 "$CLIENT_DIR/private.key"
