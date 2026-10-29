#!/usr/bin/env python3
"""Test a PhoneMic receiver's UDP acknowledgement without microphone/audio setup."""
from __future__ import annotations

import argparse
import ipaddress
import socket
import struct
import sys
import time

HEADER = struct.Struct("!4sBBHQIIQ")
STATUS = struct.Struct("!6I")


def probe(host: str, port: int, token: int, timeout: float = 2.0) -> dict:
    ipaddress.IPv4Address(host)
    if not 1024 <= port <= 65535 or not 0 < token < 2**64:
        raise ValueError("Use a port from 1024–65535 and a nonzero 16-digit hexadecimal pairing code")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect((host, port))
        started = time.monotonic_ns()
        packet = HEADER.pack(b"PMIC", 1, 2, 0, token, 0, 48000, started)
        sock.send(packet)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("No matching acknowledgement received")
            sock.settimeout(remaining)
            data = sock.recv(1024)
            received = time.monotonic_ns()
            if len(data) != HEADER.size + STATUS.size:
                continue
            magic, version, kind, frames, echoed_token, _, rate, echoed_time = HEADER.unpack_from(data)
            if (magic, version, kind, frames, echoed_token, rate, echoed_time) != (
                b"PMIC", 1, 3, 0, token, 48000, started
            ):
                continue
            queue, underruns, gaps, late, quantum, audio_packets = STATUS.unpack_from(data, HEADER.size)
            return {"rtt_ms": (received - started) / 1e6, "queue_ms": queue / 48,
                    "underruns": underruns, "gaps": gaps, "late": late,
                    "quantum": quantum, "audio_packets": audio_packets}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", help="PC LAN IPv4 address, or 127.0.0.1 when testing on that PC")
    parser.add_argument("--port", type=int, default=5555)
    parser.add_argument("--token", help="Current receiver pairing code (otherwise prompted)")
    args = parser.parse_args()
    code = (args.token or input("Receiver's current 16-digit pairing code: ")).strip()
    if len(code) != 16:
        parser.error("Pairing code must contain exactly 16 hexadecimal digits")
    try:
        token = int(code, 16)
        result = probe(args.host, args.port, token)
    except TimeoutError:
        print("No acknowledgement. Check the receiver's counters:\n"
              "  UDP stays 0: check the address, UDP port, firewall, or Wi-Fi client isolation.\n"
              "  wrong-code increases: use the pairing code from the CURRENT receiver process.\n"
              "  other-sender increases: stop the phone temporarily and wait three seconds.\n"
              "  reply-errors increases: the receiver cannot send the acknowledgement.", file=sys.stderr)
        return 2
    except (ValueError, OSError) as exc:
        print(f"Connection probe failed: {exc}", file=sys.stderr)
        return 1
    print(f"Receiver acknowledged: RTT {result['rtt_ms']:.1f} ms, quantum {result['quantum']} frames, "
          f"{result['audio_packets']} audio packets accepted.")
    print("UDP and pairing work from this device. This does not test the iPhone's permissions or audio capture.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
