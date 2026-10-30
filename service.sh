#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
task_config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
task_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
task_config="$task_config_home/phonemic/receiver.conf"
task_binary="$task_data_home/phonemic/phonemic"
task_unit="$task_config_home/systemd/user/phonemic.service"
task_command="${1:---help}"
if (($#)); then shift; fi

usage() {
  cat <<'HELP'
Usage: ./service.sh COMMAND [SETTINGS]

  install       Install/update, enable at login, and start the user service.
  configure     Save settings and restart the installed service.
  settings      Show the saved pairing code and settings.
  start|stop|restart|status
  logs          Follow the service's journal.
  enable        Enable at login and start now.
  disable       Disable at login and stop now.
  uninstall     Remove the user service and its binary; keep the settings.

Settings for install/configure:
  --token 0123abcd    Fixed nonzero eight-digit hex pairing code
  --port 5555        UDP listening port
  --jitter-ms 10     Jitter buffer, 5–40 ms
  --bind 0.0.0.0     IPv4 listening address

First install: ./build.sh --install-service -- --token 0123abcd
Update later:  ./build.sh --update --install-service
Change code:   ./service.sh configure --token a1b2c3d4
Run these as your desktop user, without sudo. Existing settings survive updates.
HELP
}

if [[ "$task_command" == --help || "$task_command" == -h ]]; then usage; exit 0; fi
if [[ "$(uname -s)" != Linux || "$EUID" == 0 ]]; then
  printf 'Run this on Linux as your desktop user, without sudo.\n' >&2
  exit 1
fi
for task_path in "$task_config_home" "$task_data_home"; do
  if [[ "$task_path" != /* || "$task_path" == *$'\n'* || "$task_path" == *$'\r'* ]]; then
    printf 'XDG config/data paths must be absolute paths without newlines.\n' >&2
    exit 1
  fi
done

task_settings=()
while (($#)); do
  case "$1" in
    --token|--port|--jitter-ms|--bind)
      if (($# < 2)); then printf 'Missing value for %s\n' "$1" >&2; exit 2; fi
      task_settings+=("$1" "$2"); shift 2 ;;
    *) printf 'Unknown service setting: %s\n' "$1" >&2; exit 2 ;;
  esac
done
if ((${#task_settings[@]})) && [[ "$task_command" != install && "$task_command" != configure ]]; then
  printf 'Settings are supported by install and configure only.\n' >&2
  exit 2
fi

task_temporaries=()
cleanup() {
  for task_file in "${task_temporaries[@]}"; do rm -f -- "$task_file"; done
}
trap cleanup EXIT

save_settings() {
  local task_tool="$1"
  local -a task_input=(--no-config)
  if [[ -e "$task_config" || -L "$task_config" ]]; then
    task_input=(--config "$task_config")
    if ((${#task_settings[@]} == 0)); then
      "$task_tool" "${task_input[@]}" --check-config
      return
    fi
  fi
  mkdir -p -- "$(dirname -- "$task_config")"
  local task_candidate
  task_candidate="$(mktemp "$task_config.candidate.XXXXXX")"
  task_temporaries+=("$task_candidate")
  "$task_tool" "${task_input[@]}" "${task_settings[@]}" --save-config "$task_candidate"
  mv -f -- "$task_candidate" "$task_config"
  printf 'Settings saved: %s\n' "$task_config"
}

# systemd parses ExecStart itself: quote paths, escape specifiers and dollar
# expansion, and never pass settings through a shell or source the config file.
unit_path() {
  local task_value="$1"
  task_value="${task_value//\\/\\\\}"
  task_value="${task_value//\"/\\\"}"
  task_value="${task_value//%/%%}"
  task_value="${task_value//\$/\$\$}"
  printf '"%s"' "$task_value"
}

case "$task_command" in
  install)
    task_build_binary="$task_root/build/linux/phonemic"
    if [[ ! -x "$task_build_binary" ]]; then
      printf 'Build the receiver first: ./build.sh --install-service\n' >&2
      exit 1
    fi
    save_settings "$task_build_binary"
    mkdir -p -- "$(dirname -- "$task_binary")" "$(dirname -- "$task_unit")"
    task_binary_temp="$(mktemp "$task_binary.XXXXXX")"
    task_unit_temp="$(mktemp "$task_unit.XXXXXX")"
    task_temporaries+=("$task_binary_temp" "$task_unit_temp")
    install -m755 -- "$task_build_binary" "$task_binary_temp"
    while IFS= read -r task_line || [[ -n "$task_line" ]]; do
      case "$task_line" in
        ExecStart=*) printf 'ExecStart=%s --config %s --quiet\n' "$(unit_path "$task_binary")" "$(unit_path "$task_config")" ;;
        *) printf '%s\n' "$task_line" ;;
      esac
    done < "$task_root/linux/systemd/phonemic.service.in" > "$task_unit_temp"
    chmod 644 "$task_unit_temp"
    if systemctl --user is-active --quiet phonemic.service; then systemctl --user stop phonemic.service; fi
    mv -f -- "$task_binary_temp" "$task_binary"
    mv -f -- "$task_unit_temp" "$task_unit"
    systemctl --user daemon-reload
    systemctl --user enable --now "$task_unit"
    printf 'PhoneMic starts with your Linux session. Check: ./service.sh status\nLogs: ./service.sh logs\n'
    ;;
  configure)
    if [[ ! -x "$task_binary" || ! -f "$task_unit" ]]; then
      printf 'Install the service first: ./build.sh --install-service\n' >&2; exit 1
    fi
    if ((${#task_settings[@]} == 0)); then printf 'Provide settings, e.g. --token 0123abcd\n' >&2; exit 2; fi
    save_settings "$task_binary"
    systemctl --user restart phonemic.service
    ;;
  settings)
    if [[ ! -x "$task_binary" ]]; then printf 'Install the service first: ./build.sh --install-service\n' >&2; exit 1; fi
    "$task_binary" --config "$task_config" --check-config
    ;;
  start|stop|restart|status) systemctl --user "$task_command" phonemic.service --no-pager ;;
  logs) exec journalctl --user -u phonemic.service -f ;;
  enable) systemctl --user enable --now phonemic.service ;;
  disable) systemctl --user disable --now phonemic.service ;;
  uninstall)
    systemctl --user disable --now phonemic.service
    rm -f -- "$task_unit" "$task_binary"
    systemctl --user daemon-reload
    printf 'Service removed. Settings kept at %s\n' "$task_config"
    ;;
  *) printf 'Unknown service command: %s\n' "$task_command" >&2; usage >&2; exit 2 ;;
esac
