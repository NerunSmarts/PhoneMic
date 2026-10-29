#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
task_build="$task_root/build/linux"
task_update=0
task_run=0

usage() {
  cat <<'HELP'
Usage: ./build.sh [--update] [--run] [-- RECEIVER_OPTIONS]

Configure, build, and test the Linux PhoneMic receiver.
  --update  Pull the current branch with git pull --ff-only before building.
  --run     Start the receiver after a successful build and tests.
  --        Pass subsequent options to the receiver (requires --run).

Examples:
  ./build.sh
  ./build.sh --update --run
  ./build.sh --run -- --jitter-ms 5 --port 5555

Stop an existing receiver with Ctrl-C before starting another one.
HELP
}

while (($#)); do
  case "$1" in
    --update) task_update=1; shift ;;
    --run) task_run=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --) shift; break ;;
    *) printf 'Unknown build option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if (($# && !task_run)); then
  printf 'Receiver options require --run. See ./build.sh --help.\n' >&2
  exit 2
fi
if [[ "$(uname -s)" != Linux ]]; then
  printf 'This script builds the Linux receiver. Open ios/PhoneMic.xcodeproj in Xcode for the iOS app.\n' >&2
  exit 1
fi
for task_command in cmake ctest pkg-config c++; do
  if ! command -v "$task_command" >/dev/null 2>&1; then
    printf 'Missing %s. On CachyOS install dependencies with:\n  sudo pacman -S --needed base-devel cmake pkgconf pipewire\n' "$task_command" >&2
    exit 1
  fi
done
if ! pkg-config --atleast-version=0.3.49 libpipewire-0.3; then
  printf 'PipeWire development files are missing or too old. On CachyOS: sudo pacman -S --needed pipewire\n' >&2
  exit 1
fi
if ((task_update)); then
  git -C "$task_root" pull --ff-only
fi

cmake -S "$task_root" -B "$task_build" -DCMAKE_BUILD_TYPE=Release -DPHONEMIC_BUILD_RECEIVER=ON
cmake --build "$task_build" --parallel
ctest --test-dir "$task_build" --output-on-failure
if ((task_run)); then
  exec "$task_build/phonemic" "$@"
fi
printf 'Built receiver: %s\nStart it with ./build.sh --run or run the binary directly.\n' "$task_build/phonemic"
