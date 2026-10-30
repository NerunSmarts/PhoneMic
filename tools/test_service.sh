#!/usr/bin/env bash
# Integration test for an isolated CI account with a live systemd user manager.
set -euo pipefail
if [[ "${PHONEMIC_SERVICE_TEST:-}" != 1 ]]; then
  printf 'Run only in a disposable Linux test account with PHONEMIC_SERVICE_TEST=1.\n' >&2
  exit 1
fi
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"
if systemctl --user cat phonemic.service >/dev/null 2>&1; then
  printf 'A PhoneMic service already exists in this account; refusing to replace it in a test.\n' >&2
  exit 1
fi
task_temp="$(mktemp -d)"
# Exercise real unit escaping and installation outside the manager's usual unit
# search path, including spaces, a percent specifier, and a literal dollar sign.
export XDG_CONFIG_HOME="$task_temp/config with spaces % \$"
export XDG_DATA_HOME="$task_temp/data with spaces % \$"
task_config="$XDG_CONFIG_HOME/phonemic/receiver.conf"
cleanup() {
  local task_result=$?
  if ((task_result)); then
    systemctl --user show phonemic.service --property=ExecStart || true
    journalctl --user -u phonemic.service -n 80 --no-pager || true
  fi
  ./service.sh uninstall || true
  rm -rf -- "$task_temp"
  exit "$task_result"
}
trap cleanup EXIT
wait_for_receiver() {
  local task_token="$1" task_port="$2"
  local task_deadline=$((SECONDS + 20))
  until python3 tools/probe_receiver.py 127.0.0.1 --port "$task_port" --token "$task_token" > "$task_temp/probe.log" 2>&1; do
    if ((SECONDS >= task_deadline)); then cat "$task_temp/probe.log"; return 1; fi
    sleep 0.2
  done
  cat "$task_temp/probe.log"
  python3 - <<'PY'
import json, subprocess, time
deadline = time.monotonic() + 10
while True:
    nodes = json.loads(subprocess.check_output(['pw-dump']))
    if any(n.get('info', {}).get('props', {}).get('node.name') == 'phonemic' for n in nodes):
        break
    if time.monotonic() >= deadline:
        raise SystemExit('PhoneMic UDP replied but the PipeWire microphone node is missing')
    time.sleep(0.1)
PY
}

systemctl --user start pipewire.service wireplumber.service
./build.sh --install-service -- --token 0123abcd
systemctl --user is-enabled --quiet phonemic.service
wait_for_receiver 0123abcd 5555
python3 - "$task_config" <<'PY'
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY

task_original="$(cat "$task_config")"
task_pid="$(systemctl --user show phonemic.service --property=MainPID --value)"
if ./service.sh configure --token not-a-code; then
  printf 'Invalid settings were unexpectedly accepted.\n' >&2; exit 1
fi
[[ "$(cat "$task_config")" == "$task_original" ]]
[[ "$(systemctl --user show phonemic.service --property=MainPID --value)" == "$task_pid" ]]

./service.sh configure --token a1b2c3d4 --port 5556 --jitter-ms 5
wait_for_receiver a1b2c3d4 5556
task_configured="$(cat "$task_config")"
./service.sh restart
wait_for_receiver a1b2c3d4 5556
[[ "$(cat "$task_config")" == "$task_configured" ]]

# A build/install update preserves the entire file, not just the code.
./service.sh install
wait_for_receiver a1b2c3d4 5556
[[ "$(cat "$task_config")" == "$task_configured" ]]

# PipeWire restarts must bring the virtual source back with the same code.
systemctl --user restart pipewire.service
wait_for_receiver a1b2c3d4 5556

./service.sh uninstall
[[ -f "$task_config" && ! -e "$XDG_DATA_HOME/phonemic/phonemic" ]]
./service.sh install
wait_for_receiver a1b2c3d4 5556
[[ "$(cat "$task_config")" == "$task_configured" ]]
printf 'Service install, configuration, restart, update, and reinstall passed.\n'
