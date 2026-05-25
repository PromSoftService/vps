#!/usr/bin/env python3

import argparse
import json
from pathlib import Path


def build_config(
    domain: str,
    uuid: str,
    reality_server_name: str,
    reality_public_key: str,
    reality_short_id: str,
    fingerprint: str,
    spiderx: str,
    remark: str,
    mux_enabled: bool,
    mux_concurrency: int,
    mux_xudp_concurrency: int,
    mux_xudp_proxy_udp_443: str,
    client_sockopt_enabled: bool,
    client_sockopt_tcp_fast_open: bool,
    client_sockopt_tcp_keep_alive_idle: int,
    client_sockopt_tcp_keep_alive_interval: int,
) -> dict:
    stream_settings = {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
            "serverName": reality_server_name,
            "fingerprint": fingerprint,
            "password": reality_public_key,
            "shortId": reality_short_id,
            "spiderX": spiderx
        }
    }

    if client_sockopt_enabled:
        stream_settings["sockopt"] = {
            "tcpFastOpen": client_sockopt_tcp_fast_open,
            "tcpKeepAliveIdle": client_sockopt_tcp_keep_alive_idle,
            "tcpKeepAliveInterval": client_sockopt_tcp_keep_alive_interval,
        }

    proxy_outbound = {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
            "vnext": [
                {
                    "address": domain,
                    "port": 443,
                    "users": [
                        {
                            "id": uuid,
                            "encryption": "none",
                            "flow": "xtls-rprx-vision"
                        }
                    ]
                }
            ]
        },
        "streamSettings": stream_settings,
    }

    if mux_enabled:
        proxy_outbound["mux"] = {
            "enabled": True,
            "concurrency": mux_concurrency,
            "xudpConcurrency": mux_xudp_concurrency,
            "xudpProxyUDP443": mux_xudp_proxy_udp_443,
        }

    return {
        "remarks": remark,
        "log": {
            "loglevel": "warning"
        },
        "dns": {
            "servers": [
                "https+local://1.1.1.1/dns-query",
                "https+local://1.0.0.1/dns-query",
                "localhost"
            ],
            "queryStrategy": "UseIPv4"
        },
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": 10808,
                "protocol": "socks",
                "settings": {
                    "udp": True
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls", "quic"]
                }
            },
            {
                "tag": "http-in",
                "listen": "127.0.0.1",
                "port": 10809,
                "protocol": "http",
                "settings": {}
            }
        ],
        "outbounds": [
            proxy_outbound,
            {
                "tag": "direct",
                "protocol": "freedom"
            },
            {
                "tag": "block",
                "protocol": "blackhole"
            }
        ]
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate client config for VLESS + REALITY + RAW with optional outbound mux and stream sockopt."
    )
    parser.add_argument("domain", help="Server domain")
    parser.add_argument("uuid", help="Client UUID")
    parser.add_argument("reality_server_name", help="REALITY serverName")
    parser.add_argument("reality_public_key", help="REALITY public key")
    parser.add_argument("reality_short_id", help="REALITY shortId")
    parser.add_argument(
        "--fingerprint",
        default="chrome",
        help="REALITY fingerprint (default: chrome)",
    )
    parser.add_argument(
        "--spiderx",
        default="/",
        help="REALITY spiderX (default: /)",
    )
    parser.add_argument(
        "--remark",
        default="reality raw",
        help="Human-readable config remark",
    )
    parser.add_argument(
        "--mux-enabled",
        action="store_true",
        help="Enable outbound mux for proxy outbound",
    )
    parser.add_argument(
        "--mux-concurrency",
        type=int,
        default=8,
        help="Mux concurrency value",
    )
    parser.add_argument(
        "--mux-xudp-concurrency",
        type=int,
        default=16,
        help="Mux xudpConcurrency value",
    )
    parser.add_argument(
        "--mux-xudp-proxy-udp-443",
        default="reject",
        help="Mux xudpProxyUDP443 value",
    )
    parser.add_argument(
        "--client-sockopt-enabled",
        action="store_true",
        help="Enable streamSettings.sockopt in generated client config",
    )
    parser.add_argument(
        "--client-sockopt-tcp-fast-open",
        choices=["true", "false"],
        default="false",
        help="Client sockopt tcpFastOpen",
    )
    parser.add_argument(
        "--client-sockopt-tcp-keep-alive-idle",
        type=int,
        default=300,
        help="Client sockopt tcpKeepAliveIdle",
    )
    parser.add_argument(
        "--client-sockopt-tcp-keep-alive-interval",
        type=int,
        default=0,
        help="Client sockopt tcpKeepAliveInterval",
    )
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="Output JSON file path",
    )

    args = parser.parse_args()

    config = build_config(
        domain=args.domain,
        uuid=args.uuid,
        reality_server_name=args.reality_server_name,
        reality_public_key=args.reality_public_key,
        reality_short_id=args.reality_short_id,
        fingerprint=args.fingerprint,
        spiderx=args.spiderx,
        remark=args.remark,
        mux_enabled=args.mux_enabled,
        mux_concurrency=args.mux_concurrency,
        mux_xudp_concurrency=args.mux_xudp_concurrency,
        mux_xudp_proxy_udp_443=args.mux_xudp_proxy_udp_443,
        client_sockopt_enabled=args.client_sockopt_enabled,
        client_sockopt_tcp_fast_open=(args.client_sockopt_tcp_fast_open == "true"),
        client_sockopt_tcp_keep_alive_idle=args.client_sockopt_tcp_keep_alive_idle,
        client_sockopt_tcp_keep_alive_interval=args.client_sockopt_tcp_keep_alive_interval,
    )

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"Config written to: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())