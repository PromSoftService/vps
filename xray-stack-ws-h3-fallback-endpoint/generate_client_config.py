#!/usr/bin/env python3

import argparse
import json
from pathlib import Path


def yes_no(value: str, argument_name: str) -> bool:
    normalized = value.strip().lower()
    if normalized == "yes":
        return True
    if normalized == "no":
        return False
    raise SystemExit(f"{argument_name} must be 'yes' or 'no'")


def parse_alpn(raw: str) -> list[str]:
    values = [part.strip() for part in raw.split(",") if part.strip()]
    if not values:
        raise SystemExit("--alpn must contain at least one value")
    return values


def build_config(
    domain: str,
    uuid: str,
    path: str,
    doh: str | None,
    remark: str,
    fingerprint: str,
    alpn: list[str],
    client_udp_enabled: bool,
    client_sniff_quic: bool,
    mux_enabled: bool,
    mux_concurrency: int,
    mux_xudp_concurrency: int,
    mux_xudp_proxy_udp_443: str,
) -> dict:
    sniff_dest_override = ["http", "tls"]
    if client_sniff_quic:
        sniff_dest_override.append("quic")

    mux: dict = {
        "enabled": mux_enabled,
        "concurrency": mux_concurrency if mux_enabled else -1,
        "xudpConcurrency": mux_xudp_concurrency,
        "xudpProxyUDP443": mux_xudp_proxy_udp_443 if mux_enabled else "",
    }

    proxy_outbound: dict = {
        "tag": "proxy",
        "protocol": "vless",
        "mux": mux,
        "settings": {
            "vnext": [
                {
                    "address": domain,
                    "port": 443,
                    "users": [
                        {
                            "id": uuid,
                            "encryption": "none",
                            "security": "auto",
                            "level": 8,
                        }
                    ],
                }
            ]
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "tlsSettings": {
                "allowInsecure": False,
                "serverName": domain,
                "fingerprint": fingerprint,
                "alpn": alpn,
            },
            "wsSettings": {
                "path": path,
                "headers": {
                    "Host": domain,
                },
            },
        },
    }

    config = {
        "remarks": remark,
        "log": {
            "loglevel": "warning",
        },
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": 10808,
                "protocol": "socks",
                "settings": {
                    "auth": "noauth",
                    "udp": client_udp_enabled,
                    "userLevel": 8,
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": sniff_dest_override,
                },
            },
            {
                "tag": "http-in",
                "listen": "127.0.0.1",
                "port": 10809,
                "protocol": "http",
                "settings": {
                    "userLevel": 8,
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": sniff_dest_override,
                },
            },
        ],
        "outbounds": [
            proxy_outbound,
            {
                "tag": "direct",
                "protocol": "freedom",
                "settings": {
                    "domainStrategy": "UseIPv4",
                },
            },
            {
                "tag": "block",
                "protocol": "blackhole",
                "settings": {
                    "response": {
                        "type": "http",
                    },
                },
            },
        ],
        "policy": {
            "levels": {
                "8": {
                    "connIdle": 300,
                    "downlinkOnly": 1,
                    "handshake": 4,
                    "uplinkOnly": 1,
                }
            },
            "system": {
                "statsInboundDownlink": True,
                "statsInboundUplink": True,
                "statsOutboundDownlink": True,
                "statsOutboundUplink": True,
            },
        },
        "stats": {},
    }

    if doh:
        config["dns"] = {
            "servers": [
                doh,
                "localhost",
            ],
            "queryStrategy": "UseIPv4",
        }

    return config


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate client config for VLESS + WebSocket + TLS with nginx TLS/H3 fallback site."
    )
    parser.add_argument("domain", help="Server domain")
    parser.add_argument("uuid", help="Client UUID")
    parser.add_argument("path", help="WebSocket path")
    parser.add_argument(
        "--doh",
        default=None,
        help="Optional DoH server URL, for example https://1.1.1.1/dns-query",
    )
    parser.add_argument(
        "--remark",
        default="ws tls fallback",
        help="Human-readable config remark",
    )
    parser.add_argument(
        "--fingerprint",
        default="chrome",
        help="uTLS fingerprint, for example chrome, firefox, safari",
    )
    parser.add_argument(
        "--alpn",
        default="http/1.1",
        help="Comma-separated TLS ALPN list. For WebSocket keep http/1.1 by default.",
    )
    parser.add_argument(
        "--client-udp-enabled",
        default="no",
        help="Enable UDP on local SOCKS inbound: yes / no",
    )
    parser.add_argument(
        "--client-sniff-quic",
        default="no",
        help="Add quic to sniffing.destOverride: yes / no",
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
        "-o",
        "--output",
        required=True,
        help="Output JSON file path",
    )

    args = parser.parse_args()

    config = build_config(
        domain=args.domain,
        uuid=args.uuid,
        path=args.path,
        doh=args.doh,
        remark=args.remark,
        fingerprint=args.fingerprint,
        alpn=parse_alpn(args.alpn),
        client_udp_enabled=yes_no(args.client_udp_enabled, "--client-udp-enabled"),
        client_sniff_quic=yes_no(args.client_sniff_quic, "--client-sniff-quic"),
        mux_enabled=args.mux_enabled,
        mux_concurrency=args.mux_concurrency,
        mux_xudp_concurrency=args.mux_xudp_concurrency,
        mux_xudp_proxy_udp_443=args.mux_xudp_proxy_udp_443,
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
