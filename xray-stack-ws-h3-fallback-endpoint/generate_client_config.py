#!/usr/bin/env python3

import argparse
import json
from pathlib import Path


def parse_bool(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise SystemExit(f"Invalid boolean value: {value!r}")


def parse_alpn(raw: str) -> list[str]:
    values = [v.strip() for v in raw.split(",") if v.strip()]
    return values or ["http/1.1"]


def build_config(
    domain: str,
    uuid: str,
    path: str,
    doh: str | None,
    remark: str,
    fingerprint: str,
    socks_udp: bool,
    sniff_quic: bool,
    alpn: list[str],
    mux_enabled: bool,
    mux_concurrency: int,
    mux_xudp_concurrency: int,
    mux_xudp_proxy_udp_443: str,
) -> dict:
    sniff_dest = ["http", "tls"]
    if sniff_quic:
        sniff_dest.append("quic")

    proxy_outbound: dict = {
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
                "serverName": domain,
                "fingerprint": fingerprint,
                "allowInsecure": False,
                "alpn": alpn,
            },
            "wsSettings": {
                "path": path,
                "headers": {
                    "Host": domain,
                },
            },
        },
        "mux": {
            "enabled": mux_enabled,
            "concurrency": mux_concurrency,
            "xudpConcurrency": mux_xudp_concurrency,
            "xudpProxyUDP443": mux_xudp_proxy_udp_443,
        },
    }

    config = {
        "remarks": remark,
        "log": {"loglevel": "warning"},
        "dns": {
            "queryStrategy": "UseIPv4",
            "servers": [doh, "localhost"] if doh else ["localhost"],
        },
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": 10808,
                "protocol": "socks",
                "settings": {
                    "auth": "noauth",
                    "udp": socks_udp,
                    "userLevel": 8,
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": sniff_dest,
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
                    "destOverride": sniff_dest,
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
                "0": {
                    "statsUserDownlink": True,
                    "statsUserUplink": True,
                },
                "8": {
                    "connIdle": 300,
                    "downlinkOnly": 1,
                    "handshake": 4,
                    "uplinkOnly": 1,
                },
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

    return config


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate client config for VLESS + WS + TLS endpoint."
    )
    parser.add_argument("domain", help="Server domain")
    parser.add_argument("uuid", help="Client UUID")
    parser.add_argument("path", help="WebSocket path")
    parser.add_argument("--doh", default=None, help="Optional DoH server URL")
    parser.add_argument("--remark", default="ws tls fallback", help="Human-readable config remark")
    parser.add_argument("--fingerprint", default="chrome", help="uTLS fingerprint")
    parser.add_argument("--socks-udp", default="false", help="true/false")
    parser.add_argument("--sniff-quic", default="false", help="true/false")
    parser.add_argument("--alpn", default="http/1.1", help="Comma-separated ALPN list")
    parser.add_argument("--mux-enabled", default="false", help="true/false")
    parser.add_argument("--mux-concurrency", type=int, default=-1)
    parser.add_argument("--mux-xudp-concurrency", type=int, default=8)
    parser.add_argument("--mux-xudp-proxy-udp-443", default="")
    parser.add_argument("-o", "--output", required=True, help="Output JSON file path")

    args = parser.parse_args()

    config = build_config(
        domain=args.domain,
        uuid=args.uuid,
        path=args.path,
        doh=args.doh,
        remark=args.remark,
        fingerprint=args.fingerprint,
        socks_udp=parse_bool(args.socks_udp),
        sniff_quic=parse_bool(args.sniff_quic),
        alpn=parse_alpn(args.alpn),
        mux_enabled=parse_bool(args.mux_enabled),
        mux_concurrency=args.mux_concurrency,
        mux_xudp_concurrency=args.mux_xudp_concurrency,
        mux_xudp_proxy_udp_443=args.mux_xudp_proxy_udp_443,
    )

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Config written to: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
