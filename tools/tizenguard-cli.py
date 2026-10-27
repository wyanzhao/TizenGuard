#!/usr/bin/env python3
"""Owner mTLS CLI for TizenGuard.Service maintenance endpoints."""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        nargs="?",
        default="status",
        choices=["status", "enable", "apply", "disable", "restore-sdk", "reboot"],
        help="Maintenance operation to invoke on TizenGuard.Service",
    )
    parser.add_argument("--host", required=True, help="TV LAN IP or hostname")
    parser.add_argument("--port", type=int, default=28443, help="TizenGuard mTLS port (default: 28443)")
    parser.add_argument(
        "--cert-dir",
        type=Path,
        required=True,
        help="Directory containing server.pem, client.pem, and client-key.pem",
    )
    parser.add_argument("--timeout", type=int, default=75, help="Request timeout in seconds")
    args = parser.parse_args()

    cert_dir = args.cert_dir.resolve()
    context = ssl.create_default_context(cafile=str(cert_dir / "server.pem"))
    context.load_cert_chain(str(cert_dir / "client.pem"), str(cert_dir / "client-key.pem"))

    url = f"https://{args.host}:{args.port}/v1/{args.action}"
    request = urllib.request.Request(
        url,
        data=None if args.action == "status" else b"{}",
        headers={"Content-Type": "application/json"},
        method="GET" if args.action == "status" else "POST",
    )
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=context),
    )

    try:
        with opener.open(request, timeout=args.timeout) as response:
            print(json.dumps(json.load(response), ensure_ascii=False, indent=2))
            return 0
    except urllib.error.HTTPError as error:
        sys.stderr.write(error.read().decode("utf-8", "replace") + "\n")
        return 1
    except urllib.error.URLError as error:
        sys.stderr.write(f"TizenGuard unreachable at {url}: {error.reason}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
