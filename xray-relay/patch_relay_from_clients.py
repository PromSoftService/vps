#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# py patch_relay_from_clients.py --relay-server-config ./server_cloudru_endpoint.json --endpoint-client-config ./client_avps.json ./client_hostkey.json --output ./server_cloudru_relay.json

from __future__ import annotations

import argparse
import copy
import json
import os
import sys
import tempfile
from typing import Any, Dict, List, Optional


GENERATED_PREFIX = "relay-"
BALANCER_TAG = "relay-balancer"
RULE_MARKER = "__relay_generated__"
DEFAULT_OBSERVATORY_PROBE_URL = "https://www.google.com/generate_204"
DEFAULT_OBSERVATORY_PROBE_INTERVAL = "10s"


def load_json(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def dump_json(data: Dict[str, Any], pretty: bool = True) -> str:
    if pretty:
        return json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    return json.dumps(data, ensure_ascii=False, separators=(",", ":"))


def atomic_write_text(path: str, text: str) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    if directory and not os.path.exists(directory):
        os.makedirs(directory, exist_ok=True)

    fd, temp_path = tempfile.mkstemp(
        prefix=".tmp_patch_relay_",
        suffix=".json",
        dir=directory if directory else None,
        text=True,
    )

    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())

        os.replace(temp_path, path)
    except Exception:
        try:
            if os.path.exists(temp_path):
                os.remove(temp_path)
        except OSError:
            pass
        raise


def ensure_list(obj: Dict[str, Any], key: str) -> List[Any]:
    if key not in obj or not isinstance(obj[key], list):
        obj[key] = []
    return obj[key]


def get_inbound_tags(config: Dict[str, Any]) -> List[str]:
    tags: List[str] = []
    for inbound in config.get("inbounds", []):
        tag = inbound.get("tag")
        if isinstance(tag, str) and tag.strip():
            tags.append(tag.strip())
    return tags


def find_proxy_outbound(client_config: Dict[str, Any]) -> Dict[str, Any]:
    outbounds = client_config.get("outbounds", [])
    if not isinstance(outbounds, list):
        raise ValueError("client config has invalid 'outbounds'")

    for outbound in outbounds:
        if not isinstance(outbound, dict):
            continue
        tag = outbound.get("tag")
        protocol = outbound.get("protocol")
        if tag == "proxy" and isinstance(protocol, str) and protocol.strip():
            return outbound

    for outbound in outbounds:
        if not isinstance(outbound, dict):
            continue
        protocol = outbound.get("protocol")
        if isinstance(protocol, str) and protocol not in ("freedom", "blackhole", "dns"):
            return outbound

    raise ValueError("unable to find proxy outbound in client config")


def infer_upstream_name(client_config: Dict[str, Any], fallback: str) -> str:
    remarks = client_config.get("remarks")
    if isinstance(remarks, str) and remarks.strip():
        cleaned = remarks.strip().lower().replace(" ", "-")
        cleaned = "".join(ch for ch in cleaned if ch.isalnum() or ch in ("-", "_"))
        if cleaned:
            return cleaned
    return fallback


def extract_vnext_identity(proxy_outbound: Dict[str, Any]) -> Dict[str, Any]:
    settings = proxy_outbound.get("settings", {})
    if not isinstance(settings, dict):
        raise ValueError("proxy outbound has invalid 'settings'")

    vnext = settings.get("vnext")
    if not isinstance(vnext, list) or not vnext:
        raise ValueError("proxy outbound settings must contain non-empty 'vnext'")

    server = vnext[0]
    if not isinstance(server, dict):
        raise ValueError("invalid first vnext entry")

    users = server.get("users")
    if not isinstance(users, list) or not users:
        raise ValueError("vnext must contain non-empty 'users'")

    user = users[0]
    if not isinstance(user, dict):
        raise ValueError("invalid first vnext user")

    address = server.get("address")
    port = server.get("port")

    if not isinstance(address, str) or not address.strip():
        raise ValueError("vnext.address is missing")
    if not isinstance(port, int):
        raise ValueError("vnext.port is missing or invalid")

    return {
        "address": address,
        "port": port,
        "user": user,
    }


def normalize_reality_settings(stream_settings: Dict[str, Any]) -> None:
    security = stream_settings.get("security")
    if security != "reality":
        return

    reality_settings = stream_settings.get("realitySettings")
    if not isinstance(reality_settings, dict):
        raise ValueError("reality outbound requires realitySettings")

    password = reality_settings.get("password")
    public_key = reality_settings.get("publicKey")

    if public_key is None:
        if not isinstance(password, str) or not password.strip():
            raise ValueError(
                "reality outbound requires publicKey, or password field to be mapped to publicKey"
            )
        reality_settings["publicKey"] = password

    reality_settings.pop("password", None)


def build_outbound_from_client(client_config: Dict[str, Any], name: str) -> Dict[str, Any]:
    proxy = find_proxy_outbound(client_config)
    protocol = proxy.get("protocol")
    if not isinstance(protocol, str) or not protocol.strip():
        raise ValueError("proxy outbound protocol is missing")

    identity = extract_vnext_identity(proxy)

    stream_settings = copy.deepcopy(proxy.get("streamSettings", {}))
    if not isinstance(stream_settings, dict):
        raise ValueError("proxy outbound streamSettings must be an object")

    normalize_reality_settings(stream_settings)

    user = copy.deepcopy(identity["user"])
    if not isinstance(user, dict):
        raise ValueError("proxy outbound user must be an object")

    outbound: Dict[str, Any] = {
        "tag": f"{GENERATED_PREFIX}{name}",
        "protocol": protocol,
        "settings": {
            "vnext": [
                {
                    "address": identity["address"],
                    "port": identity["port"],
                    "users": [user],
                }
            ]
        },
    }

    if stream_settings:
        outbound["streamSettings"] = stream_settings

    if "mux" in proxy and isinstance(proxy["mux"], dict):
        outbound["mux"] = copy.deepcopy(proxy["mux"])

    if "sendThrough" in proxy:
        outbound["sendThrough"] = proxy["sendThrough"]

    if "sockopt" in proxy and isinstance(proxy["sockopt"], dict):
        outbound["sockopt"] = copy.deepcopy(proxy["sockopt"])

    return outbound


def remove_generated_outbounds(config: Dict[str, Any]) -> None:
    outbounds = ensure_list(config, "outbounds")
    config["outbounds"] = [
        ob for ob in outbounds
        if not (
            isinstance(ob, dict)
            and isinstance(ob.get("tag"), str)
            and ob["tag"].startswith(GENERATED_PREFIX)
        )
    ]


def remove_generated_routing(config: Dict[str, Any]) -> None:
    routing = config.setdefault("routing", {})

    balancers = ensure_list(routing, "balancers")
    routing["balancers"] = [
        b for b in balancers
        if not (isinstance(b, dict) and b.get("tag") == BALANCER_TAG)
    ]

    rules = ensure_list(routing, "rules")
    routing["rules"] = [
        r for r in rules
        if not (
            isinstance(r, dict)
            and (
                r.get("balancerTag") == BALANCER_TAG
                or r.get(RULE_MARKER) is True
            )
        )
    ]


def add_generated_observatory(
    config: Dict[str, Any],
    relay_outbound_tags: List[str],
    probe_url: str,
    probe_interval: str,
) -> None:
    config["observatory"] = {
        "subjectSelector": relay_outbound_tags,
        "probeUrl": probe_url,
        "probeInterval": probe_interval,
        "enableConcurrency": True,
    }


def add_generated_routing(
    config: Dict[str, Any],
    relay_outbound_tags: List[str],
    apply_to_inbounds: Optional[List[str]],
) -> None:
    routing = config.setdefault("routing", {})
    balancers = ensure_list(routing, "balancers")
    rules = ensure_list(routing, "rules")

    balancer: Dict[str, Any] = {
        "tag": BALANCER_TAG,
        "selector": relay_outbound_tags,
        "strategy": {"type": "leastPing"},
    }
    balancers.append(balancer)

    rule: Dict[str, Any] = {
        "type": "field",
        "balancerTag": BALANCER_TAG,
        RULE_MARKER: True,
    }
    if apply_to_inbounds:
        rule["inboundTag"] = apply_to_inbounds

    rules.append(rule)


def patch_relay_config(
    relay_server_config: Dict[str, Any],
    endpoint_client_configs: List[Dict[str, Any]],
    apply_to_inbounds: Optional[List[str]],
    probe_url: str = DEFAULT_OBSERVATORY_PROBE_URL,
    probe_interval: str = DEFAULT_OBSERVATORY_PROBE_INTERVAL,
) -> Dict[str, Any]:
    if len(endpoint_client_configs) != 2:
        raise ValueError("exactly 2 endpoint client configs are required")

    patched = copy.deepcopy(relay_server_config)

    if apply_to_inbounds is None:
        apply_to_inbounds = get_inbound_tags(patched) or None

    names: List[str] = []
    relay_outbounds: List[Dict[str, Any]] = []

    for idx, client_cfg in enumerate(endpoint_client_configs, start=1):
        inferred_name = infer_upstream_name(client_cfg, f"endpoint{idx}")
        name = inferred_name
        suffix = 2
        while name in names:
            name = f"{inferred_name}-{suffix}"
            suffix += 1
        names.append(name)

        relay_outbounds.append(build_outbound_from_client(client_cfg, name))

    remove_generated_outbounds(patched)
    remove_generated_routing(patched)

    outbounds = ensure_list(patched, "outbounds")
    outbounds.extend(relay_outbounds)

    relay_tags = [ob["tag"] for ob in relay_outbounds]

    add_generated_observatory(
        patched,
        relay_tags,
        probe_url=probe_url,
        probe_interval=probe_interval,
    )

    add_generated_routing(
        patched,
        relay_tags,
        apply_to_inbounds=apply_to_inbounds,
    )

    return patched


def parse_inbound_tags_arg(value: Optional[str]) -> Optional[List[str]]:
    if value is None:
        return None
    parts = [x.strip() for x in value.split(",")]
    parts = [x for x in parts if x]
    return parts or None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build relay server config from relay server JSON + 2 endpoint client JSON configs."
    )
    parser.add_argument(
        "--relay-server-config",
        required=True,
        help="Path to relay server-side config.json",
    )
    parser.add_argument(
        "--endpoint-client-config",
        required=True,
        nargs=2,
        help="Paths to 2 endpoint client config.json files",
    )
    parser.add_argument(
        "--output",
        required=False,
        help="Optional path to write patched config.json",
    )
    parser.add_argument(
        "--apply-to-inbounds",
        default=None,
        help="Optional comma-separated inbound tags to attach the balancer rule to. "
             "Default: all relay server inbound tags.",
    )
    parser.add_argument(
        "--probe-url",
        default=DEFAULT_OBSERVATORY_PROBE_URL,
        help="URL used by observatory to probe relay outbounds. "
             f"Default: {DEFAULT_OBSERVATORY_PROBE_URL}",
    )
    parser.add_argument(
        "--probe-interval",
        default=DEFAULT_OBSERVATORY_PROBE_INTERVAL,
        help="Observatory probe interval. "
             f"Default: {DEFAULT_OBSERVATORY_PROBE_INTERVAL}",
    )
    parser.add_argument(
        "--compact",
        action="store_true",
        help="Print compact JSON instead of pretty JSON.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        relay_server_config = load_json(args.relay_server_config)
        endpoint_client_configs = [load_json(path) for path in args.endpoint_client_config]
        apply_to_inbounds = parse_inbound_tags_arg(args.apply_to_inbounds)

        patched = patch_relay_config(
            relay_server_config=relay_server_config,
            endpoint_client_configs=endpoint_client_configs,
            apply_to_inbounds=apply_to_inbounds,
            probe_url=args.probe_url,
            probe_interval=args.probe_interval,
        )

        rendered = dump_json(patched, pretty=not args.compact)

        sys.stdout.write(rendered)
        sys.stdout.flush()

        if args.output:
            atomic_write_text(args.output, rendered)
            print(f"Wrote patched config to: {args.output}", file=sys.stderr)

        return 0

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())