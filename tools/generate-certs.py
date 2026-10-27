#!/usr/bin/env python3
"""Generate mTLS server/client certificates and a TizenGuard config.json template."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import subprocess
from pathlib import Path


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_openssl(args: list[str]) -> None:
    subprocess.run(["openssl", *args], check=True)


def generate_mtls_bundle(
    output_dir: Path,
    tv_ip: str,
    sdk_host_ip: str,
    device: str,
    firmware: str,
    port: int,
    policy_path: Path,
    dotnet_sha256: str,
    tarlauncher_sha256: str,
    passwd_sha256: str,
    sdbd_pub_sha256: str,
) -> dict[str, str]:
    ipaddress.IPv4Address(tv_ip)
    ipaddress.IPv4Address(sdk_host_ip)
    output_dir.mkdir(parents=True, exist_ok=True)

    server_key = output_dir / "server-key.pem"
    server_cert = output_dir / "server.pem"
    client_key = output_dir / "client-key.pem"
    client_cert = output_dir / "client.pem"
    server_ext = output_dir / "server-ext.cnf"

    server_ext.write_text(
        f"[v3_req]\n"
        f"basicConstraints = CA:FALSE\n"
        f"keyUsage = digitalSignature, keyEncipherment\n"
        f"extendedKeyUsage = serverAuth\n"
        f"subjectAltName = IP:{tv_ip},IP:127.0.0.1\n",
        encoding="utf-8",
    )

    run_openssl(
        [
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(server_key),
            "-out",
            str(server_cert),
            "-days",
            "3650",
            "-subj",
            f"/CN={tv_ip}",
            "-extensions",
            "v3_req",
            "-config",
            str(server_ext),
        ]
    )
    server_ext.unlink(missing_ok=True)

    run_openssl(
        [
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(client_key),
            "-out",
            str(client_cert),
            "-days",
            "3650",
            "-subj",
            "/CN=tizenguard-owner",
        ]
    )

    der_proc = subprocess.run(
        ["openssl", "x509", "-in", str(client_cert), "-outform", "DER"],
        check=True,
        capture_output=True,
    )
    client_sha256 = hashlib.sha256(der_proc.stdout).hexdigest()
    policy_sha256 = sha256_file(policy_path)

    config_payload = {
        "schema": 1,
        "device": device,
        "enabled": True,
        "apply_policy": True,
        "port": port,
        "firmware": firmware,
        "sdk_host_ip": sdk_host_ip,
        "client_sha256": client_sha256,
        "policy_sha256": policy_sha256,
        "hashes": {
            "/usr/bin/dotnet": dotnet_sha256,
            "/usr/sbin/sdbd-tarlauncher": tarlauncher_sha256,
        },
        "protected_hashes": {
            "/etc/passwd": passwd_sha256,
            "/usr/share/sdbd/public.pem": sdbd_pub_sha256,
        },
    }
    config_path = output_dir / "config.json"
    config_path.write_text(json.dumps(config_payload, indent=2) + "\n", encoding="utf-8")

    for secret in (server_key, client_key, config_path):
        secret.chmod(0o600)

    return {
        "output_dir": str(output_dir),
        "client_sha256": client_sha256,
        "policy_sha256": policy_sha256,
    }


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="Directory for generated PEMs and config.json")
    parser.add_argument("--tv-ip", required=True, help="TV LAN IPv4 address for server certificate SAN")
    parser.add_argument("--sdk-host-ip", required=True, help="Workstation LAN IPv4 address for /v1/restore-sdk")
    parser.add_argument("--device", default="qn90a", choices=["qn90a", "s90d"], help="Target device profile")
    parser.add_argument("--firmware", default="T-NKM2AKUC-2310.0", help="Exact firmware version string")
    parser.add_argument("--port", type=int, default=28443, help="HTTPS port for TizenGuard.Service")
    parser.add_argument(
        "--policy-path",
        type=Path,
        default=repo_root / "policies" / "boot-policy.sh",
        help="Path to boot-policy.sh used to compute policy_sha256",
    )
    parser.add_argument(
        "--dotnet-sha256",
        default="0" * 64,
        help="SHA-256 of /usr/bin/dotnet on the target TV",
    )
    parser.add_argument(
        "--tarlauncher-sha256",
        default="0" * 64,
        help="SHA-256 of /usr/sbin/sdbd-tarlauncher on the target TV",
    )
    parser.add_argument(
        "--passwd-sha256",
        default="0" * 64,
        help="SHA-256 of /etc/passwd on the target TV",
    )
    parser.add_argument(
        "--sdbd-pub-sha256",
        default="0" * 64,
        help="SHA-256 of /usr/share/sdbd/public.pem on the target TV",
    )
    args = parser.parse_args()

    summary = generate_mtls_bundle(
        output_dir=args.output_dir.resolve(),
        tv_ip=args.tv_ip,
        sdk_host_ip=args.sdk_host_ip,
        device=args.device,
        firmware=args.firmware,
        port=args.port,
        policy_path=args.policy_path.resolve(),
        dotnet_sha256=args.dotnet_sha256,
        tarlauncher_sha256=args.tarlauncher_sha256,
        passwd_sha256=args.passwd_sha256,
        sdbd_pub_sha256=args.sdbd_pub_sha256,
    )
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
