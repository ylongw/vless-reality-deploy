#!/usr/bin/env python3
"""Parse the small deployment YAML without third-party Python packages."""

import argparse
import os
import shlex
import sys


def strip_inline_comment(line: str) -> str:
    out = []
    in_single = False
    in_double = False
    for char in line:
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single:
            in_double = not in_double
        elif char == "#" and not in_single and not in_double:
            break
        out.append(char)
    return "".join(out).rstrip()


def parse_value(value: str):
    if (
        len(value) >= 2
        and value[0] == value[-1]
        and value[0] in ("'", '"')
    ):
        return value[1:-1]
    if value.lower() in ("true", "false"):
        return value.lower() == "true"
    try:
        return int(value)
    except ValueError:
        return value


def parse_simple_yaml(path: str):
    data = {}
    stack = [(0, data)]
    with open(path, "r", encoding="utf-8") as source:
        for raw in source:
            line = strip_inline_comment(raw.rstrip("\n"))
            if not line.strip():
                continue

            indent = len(line) - len(line.lstrip(" "))
            key, separator, value = line.lstrip().partition(":")
            if not separator:
                raise ValueError(f"invalid YAML line: {raw.strip()}")

            while stack and indent < stack[-1][0]:
                stack.pop()
            if not stack:
                raise ValueError(f"invalid indentation near: {raw.strip()}")

            parent = stack[-1][1]
            key = key.strip()
            value = value.strip()
            if not key:
                raise ValueError(f"empty key near: {raw.strip()}")

            if value == "":
                child = {}
                parent[key] = child
                stack.append((indent + 2, child))
            else:
                parent[key] = parse_value(value)
    return data


def shell_quote(value) -> str:
    return shlex.quote("" if value is None else str(value))


def parse_port(value, field: str, *, allow_empty: bool) -> str:
    if value in (None, "") and allow_empty:
        return ""
    try:
        port = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must be an integer") from exc
    if not 1 <= port <= 65535:
        raise ValueError(f"{field} must be between 1 and 65535")
    return str(port)


def normalized_config(data):
    server = data.get("server") or {}
    ssh = data.get("ssh") or {}
    if not isinstance(server, dict) or not isinstance(ssh, dict):
        raise ValueError("server and ssh must be YAML mappings")

    mode = str(ssh.get("mode") or "key").strip().lower()
    if mode not in ("key", "password"):
        raise ValueError("ssh.mode must be key or password")

    host = str(ssh.get("host") or "").strip()
    if not host:
        raise ValueError("ssh.host is required")

    user = str(ssh.get("user") or "").strip()
    password = str(ssh.get("password") or "")
    if mode == "password":
        user = user or "root"
        if not password:
            raise ValueError("ssh.password is required in password mode")

    return {
        "NODE_NAME": str(server.get("name") or "Reality").strip(),
        "SERVER_ADDRESS": str(server.get("address") or "").strip(),
        "SUB_PORT": parse_port(
            server.get("sub_port", 8443), "server.sub_port", allow_empty=False
        ),
        "REALITY_SNI": str(
            server.get("reality_sni") or "www.samsung.com"
        ).strip(),
        "SSH_MODE": mode,
        "SSH_HOST": host,
        "SSH_USER": user,
        "SSH_PORT": parse_port(ssh.get("port"), "ssh.port", allow_empty=True),
        "SSH_PASSWORD": password,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Read the single-server deployment config"
    )
    parser.add_argument("--file", required=True, help="path to config.yaml")
    args = parser.parse_args()

    if not os.path.isfile(args.file):
        print(f"[ERROR] config file not found: {args.file}", file=sys.stderr)
        return 1

    try:
        config = normalized_config(parse_simple_yaml(args.file))
    except Exception as exc:
        print(f"[ERROR] invalid config: {exc}", file=sys.stderr)
        return 1

    for key, value in config.items():
        print(f"{key}={shell_quote(value)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
