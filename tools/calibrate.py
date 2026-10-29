#!/usr/bin/env python3
"""Measure the PC-speaker → iPhone → PhoneMic capture loop using chirp correlation.

Install numpy and sounddevice, then run --list-devices. With PortAudio's ALSA
pulse device, PULSE_SOURCE=phonemic selects the PipeWire virtual microphone.
This reports effective duplex callback latency, including PC audio buffering.
It is NOT an isolated network measurement or the game's input latency.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

RATE = 48000


def chirp(rate: int = RATE) -> np.ndarray:
    t = np.arange(int(rate * 0.025), dtype=np.float64) / rate
    phase = 2 * np.pi * (1800 * t + (7200 - 1800) / (2 * 0.025) * t * t)
    return (np.sin(phase) * np.hanning(len(t))).astype(np.float32)


def detect(recording: np.ndarray, probe: np.ndarray, starts: list[int],
           rate: int = RATE, max_ms: float = 500) -> list[dict]:
    """Normalized matched filter; reject silence, noise, and ambiguous peaks."""
    results = []
    energy = float(np.dot(probe, probe))
    width = len(probe)
    for start in starts:
        # Allow a small negative window to expose wrong source / bad clock alignment.
        lower = max(0, start - int(0.02 * rate))
        upper = min(len(recording), start + int(max_ms * rate / 1000) + width)
        segment = recording[lower:upper].astype(np.float64)
        if len(segment) < width:
            continue
        correlation = np.correlate(segment, probe.astype(np.float64), mode="valid")
        cumulative = np.concatenate(([0.0], np.cumsum(segment * segment)))
        local_energy = cumulative[width:] - cumulative[:-width]
        scores = np.abs(correlation) / np.sqrt(np.maximum(local_energy * energy, 1e-20))
        peak = int(np.argmax(scores))
        score = float(scores[peak])
        lag_ms = (lower + peak - start) / rate * 1000
        # Side lobes within 2 ms belong to the same chirp; distant peaks are ambiguous.
        rivals = scores.copy()
        margin = int(rate * 0.002)
        rivals[max(0, peak - margin):peak + margin + 1] = 0
        rival = float(np.max(rivals)) if len(rivals) else 0
        rms = float(np.sqrt(local_energy[peak] / width))
        valid = score >= 0.20 and score > rival * 1.3 and rms > 0.0001 and lag_ms >= 0
        results.append({"latency_ms": round(lag_ms, 3), "correlation": round(score, 3),
                        "rms": round(rms, 5), "valid": bool(valid)})
    return results


def device_arg(value: str):
    return int(value) if value.isdecimal() else value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list-devices", action="store_true")
    parser.add_argument("--input", type=device_arg, default="pulse", help="PortAudio input device name/index (default: pulse)")
    parser.add_argument("--output", type=device_arg, default="pulse", help="PortAudio speaker device name/index (default: pulse)")
    parser.add_argument("--trials", type=int, default=6)
    parser.add_argument("--volume", type=float, default=0.15, help="Probe amplitude, 0.01–0.5; start with low speaker volume")
    parser.add_argument("--json", type=Path, help="Save results as JSON")
    parser.add_argument("--recording", type=Path, help="Optionally save captured mono audio as a WAV")
    args = parser.parse_args()
    if not 3 <= args.trials <= 20 or not 0.01 <= args.volume <= 0.5:
        parser.error("Use 3–20 trials and volume 0.01–0.5")
    # Set before importing PortAudio: libpulse/ALSA pulse uses this source.
    os.environ.setdefault("PULSE_SOURCE", "phonemic")
    import sounddevice as sd
    if args.list_devices:
        print(sd.query_devices())
        return 0
    probe = chirp()
    starts = [int((1.0 + i * 0.85) * RATE) for i in range(args.trials)]
    length = starts[-1] + RATE
    playback = np.zeros(length, dtype=np.float32)
    recording = np.zeros(length, dtype=np.float32)
    for start in starts:
        playback[start:start + len(probe)] = probe * args.volume
    position = 0
    statuses = []

    def callback(indata, outdata, frames, time, status):
        nonlocal position
        if status:
            statuses.append(str(status))
        count = min(frames, length - position)
        outdata.fill(0)
        if count:
            outdata[:count, 0] = playback[position:position + count]
            recording[position:position + count] = indata[:count, 0]
        position += count
        if position >= length:
            raise sd.CallbackStop

    print("Streaming must already be active. Place the iPhone close to the PC speaker.")
    print(f"Input: {args.input} (PULSE_SOURCE={os.environ['PULSE_SOURCE']}); output: {args.output}")
    print("Playing quiet chirps. This measures the whole acoustic loop, including PC output/capture buffering.")
    with sd.Stream(device=(args.input, args.output), samplerate=RATE, channels=1,
                   dtype="float32", latency="low", blocksize=0, callback=callback) as stream:
        reported_latency = list(stream.latency)
        while stream.active:
            sd.sleep(50)
    if statuses:
        print("Audio underflow/overflow occurred; this run is invalid. Close other audio apps and retry.", file=sys.stderr)
        return 2
    trials = detect(recording, probe, starts)
    valid = [trial["latency_ms"] for trial in trials if trial["valid"]]
    if len(valid) < 3:
        print("No reliable result. Confirm the input is PhoneMic, unmute the speaker, move the phone closer, "
              "or carefully increase --volume. Avoid headphones for this test.", file=sys.stderr)
        print(json.dumps(trials, indent=2))
        return 2
    median = float(np.median(valid))
    result = {"measurement": "PC output → air → iPhone → PhoneMic → calibration capture",
              "median_ms": round(median, 2), "p95_ms": round(float(np.percentile(valid, 95)), 2),
              "min_ms": min(valid), "max_ms": max(valid), "valid_trials": len(valid), "trials": trials,
              "portaudio_reported_latency_seconds": reported_latency,
              "note": "Effective duplex callback loop latency; includes output and capture buffering. "
                      "No assumed latency has been subtracted. Excludes game input buffering."}
    print(f"Acoustic loop: median {median:.1f} ms · p95 {result['p95_ms']:.1f} ms "
          f"· range {min(valid):.1f}–{max(valid):.1f} ms ({len(valid)}/{args.trials} valid)")
    print("Use the game's own calibration for its final offset; offset sign and meaning vary by game.")
    if args.json:
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    if args.recording:
        import wave
        with wave.open(str(args.recording), "wb") as wav:
            wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(RATE)
            wav.writeframes((np.clip(recording, -1, 1) * 32767).astype("<i2").tobytes())
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as exc:
        print(f"Calibration failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
