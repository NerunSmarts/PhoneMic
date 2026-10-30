# Background receiver

PhoneMic can run as a systemd **user service** alongside your desktop's PipeWire
session. It starts at login, keeps running after you close the terminal, and
restarts after a crash or a PipeWire restart. No tray application is required.

## Install once

Stop any foreground receiver with Ctrl-C, then run these as your desktop user,
without `sudo`:

```sh
git pull --ff-only
./build.sh --install-service -- --token 0123abcd
```

Replace `0123abcd` with your chosen nonzero eight-digit hexadecimal code. Enter that
same code in the iOS app once. The phone remembers it, and the service keeps it
across restarts and updates. If you omit `--token`, setup generates a code once
and saves it. Reinstalling preserves your existing settings.

The script installs a copy of the receiver under
`${XDG_DATA_HOME:-~/.local/share}/phonemic/phonemic`, creates a user unit, and runs
`systemctl --user enable --now` for it. The service does not depend on the checkout
remaining open or staying in its original directory.

## Change settings

```sh
./service.sh configure --token a1b2c3d4
./service.sh configure --port 5555 --jitter-ms 5 --bind 0.0.0.0
./service.sh settings
```

Changes are validated before being saved, and the service restarts automatically.
Unspecified settings keep their current values. Changing the code requires updating
the iOS app's pairing field; changing the port also requires updating the phone and
your firewall rule.

The settings file is `${XDG_CONFIG_HOME:-~/.config}/phonemic/receiver.conf`, with
permissions `0600`. You can also edit it directly:

```ini
pairing_code=0123abcd
port=5555
jitter_ms=10
bind_address=0.0.0.0
```

Then run `./service.sh restart`. Unknown/duplicate settings, invalid values, and
missing codes are errors. A malformed file will not silently reset the pairing
code. Config errors stop the service instead of causing an endless restart loop;
fix the file and restart it. Configuration updates are written atomically.

## Update or manage the service

```sh
./build.sh --update --install-service  # pull, build, test, update, restart
./service.sh status
./service.sh logs                     # follow journal; Ctrl-C only stops the viewer
./service.sh stop                     # stop now; still enabled for future logins
./service.sh start
./service.sh disable                  # stop and turn off autostart
./service.sh enable                   # start and turn on autostart
./service.sh uninstall                # remove service/binary, retain settings
```

Updates preserve the settings file verbatim unless you explicitly pass settings.
The systemd unit is `phonemic.service`, so ordinary `systemctl --user` and
`journalctl --user -u phonemic.service` commands also work. The service logs startup,
connections, disconnections, and errors; it does not flood the journal with the
foreground terminal's two-second status display.

## Foreground use and packaged installs

`./build.sh --run` and `phonemic` automatically load your settings file when it
exists. CLI options override the file, regardless of argument order:

```sh
./build/linux/phonemic --jitter-ms 5
./build/linux/phonemic --config /path/to/receiver.conf --token a1b2c3d4
./build/linux/phonemic --no-config      # original defaults and fresh random code
./build/linux/phonemic --check-config   # show/validate config without starting audio
```

Only one receiver can bind a given UDP port. Stop the service before starting a
foreground receiver on its port.

The Arch package and CMake installation also include a user unit and an example
config. For a packaged install, copy `/usr/share/doc/phonemic/receiver.conf.example`
to `~/.config/phonemic/receiver.conf`, choose a code, and run
`systemctl --user enable --now phonemic.service`. Local source installations should
use the build/service scripts above.

The unit uses systemd's [user unit configuration](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html)
and [restart behavior](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html).
