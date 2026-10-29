# PhoneMic

An iOS microphone sender and CachyOS / PipeWire receiver for rhythm games. Native
RemoteIO capture → 5 ms UDP PCM packets → a selectable **PhoneMic** virtual microphone.
No server, codec, subscription, or internet connection is needed at runtime.

**Under 50 ms is the design target, not a measured guarantee.** Real latency depends
on the phone, Wi-Fi, PipeWire graph, and game's input buffers. A calibration tool
measures the PC-speaker → iPhone → virtual-microphone acoustic loop. This repository
has not yet been measured on a physical iPhone connected to CachyOS.

## CachyOS receiver

Requires a running PipeWire user session (normal CachyOS desktop setup).

```sh
sudo pacman -S --needed base-devel cmake pkgconf pipewire
cmake -S . -B build/linux -DCMAKE_BUILD_TYPE=Release
cmake --build build/linux --parallel
ctest --test-dir build/linux --output-on-failure
./build/linux/phonemic
```

The terminal prints a fresh 16-digit pairing code and listens on UDP port 5555.
Find your PC's LAN IPv4 address with `hostname -I` or `ip -4 addr`. Use the address
on the same LAN as the phone, avoiding VPN, container, and loopback addresses.
Enter that address and pairing code in the iOS app. Keep the terminal running.

Select **PhoneMic** in the game or emulator's microphone settings. For applications
that follow the desktop default, `pactl set-default-source phonemic` selects it;
this changes the desktop default until you change it back. `pavucontrol` can route
individual recording applications to PhoneMic instead. A native virtual microphone
does not emulate a Rock Band USB device: a console emulator must also support and
enable its own emulated USB microphone. This does not send audio to a physical console.

If you run a firewall, permit UDP 5555 **from your phone/LAN only**. Router client
isolation and guest Wi-Fi can block phone-to-PC traffic. Do not forward this port
from the internet.

Options:

```sh
./build/linux/phonemic --jitter-ms 5           # smaller buffer; less tolerance for Wi-Fi jitter
./build/linux/phonemic --jitter-ms 20          # try this if the underrun counter increases
./build/linux/phonemic --bind 192.168.1.100 --port 5555
./build/linux/phonemic --token 0123456789abcdef # optional fixed 16-digit hex pairing code
```

The default jitter target is 10 ms; range 5–40 ms. The PipeWire node requests a
128-frame / 48 kHz quantum (~2.7 ms), but the graph can choose a larger one. Check
`pw-top` and the app's reported quantum. The receiver does not force global audio
settings. Its queue starts with the target cushion and sheds stale audio after
stalls rather than building an ever-growing delay. Rare single-frame corrections
compensate for independent phone and PC clocks.

Optional local Arch package:

```sh
cd linux/packaging
makepkg -si
phonemic
```

## iOS app

Open [ios/PhoneMic.xcodeproj](ios/PhoneMic.xcodeproj) in Xcode. Select the PhoneMic
target, choose your signing team and a unique bundle identifier, and run on a
physical iPhone (iOS 17 or later). The checked-in project is ready to open; XcodeGen
is only needed after changing `ios/project.yml`:

```sh
xcodegen generate --spec ios/project.yml
```

1. Connect to the PC's LAN over Wi-Fi, preferably 5 or 6 GHz.
2. Enter the PC's IPv4 address, port, and terminal pairing code.
3. Tap **Start streaming** and allow microphone and local network access.
4. Wait for the **LIVE** indicator, then select PhoneMic in the game.

The app uses the built-in microphone, requests a 5 ms hardware I/O period, and
disables voice processing via measurement mode. Audio runs in the background and
with the screen locked; calls, Siri, and route changes can interrupt it. Tap Start
again after an interruption. The screen stays awake while streaming in the foreground.
Bluetooth microphone paths are deliberately avoided.

The level meter, RTT, receiver queue, actual graph quantum, packet gaps, and
underruns help tune the setup. A LIVE indicator confirms a matching receiver
responded; the game must still open the virtual microphone separately. If it stays
at “Waiting,” check the pairing code, address, firewall, and iOS Settings → Apps →
PhoneMic → Local Network. If the receiver restarts, copy its new code into the app.

## Acoustic latency calibration

Connect the phone and start streaming first. Use a **speaker**, place the phone
close to it, and start with low speaker volume. Disable microphone monitoring to
avoid feedback. On CachyOS:

```sh
sudo pacman -S --needed python python-numpy python-sounddevice portaudio pipewire-pulse alsa-plugins
python tools/calibrate.py --list-devices
PULSE_SOURCE=phonemic python tools/calibrate.py --input pulse --output pulse --json calibration.json
```

The default `pulse` devices use PortAudio's ALSA PulseAudio plugin. If `pulse` is not
listed, install `alsa-plugins`, restart the tool, and inspect `--list-devices`.
Explicit PortAudio names or numeric indices are also accepted. Make sure the
calibration recording stream is connected to **PhoneMic** in your audio mixer;
recording from another microphone gives an unrelated result. `PULSE_SINK` can
select a particular speaker sink. Turn off effects such as noise suppression for
the calibration recording stream.

The tool plays six chirps, matches them in the returned audio, and reports median,
p95, range, and valid trial count. It rejects silence, unrelated noise, ambiguous
echoes, and runs with audio underflows/overflows. Try `--volume 0.25` if the probe
is too quiet. `--recording capture.wav` optionally saves the returned audio locally.
No recording is saved by default.

**What it measures:** effective full-duplex callback delay through PC audio output,
speaker, air, iPhone capture, network, receiver, and the calibration program's input
buffering. It includes PC output/capture overhead and acoustic travel (~3 ms per
metre), and excludes the game's own input pipeline. It is useful for comparing
setups and measuring the practical acoustic loop, but it is not isolated one-way
microphone transport latency. No assumed sound-card delay is subtracted. Use the
game's own calibration for the final offset; games differ in offset direction and
meaning. Cross-host clocks are not used by this tool.

The app's **estimated audio path** is separate: reported iOS input latency + I/O
period + up to 5 ms packetization + half network RTT + observed receiver queue +
one PipeWire quantum. RTT/2 assumes symmetric networking, snapshots vary within
audio cycles, and OS/device buffering may add delay. Treat it as a tuning aid,
never as an E2E measurement.

## Latency tuning

- Wire the PC to the access point and keep the phone near it on 5/6 GHz Wi-Fi.
- Begin at the default 10 ms jitter target, then try 5 ms if underruns stay flat.
- Avoid Bluetooth speakers/headphones during measurement. Use wired game audio.
- Check the real PipeWire quantum with `pw-top`; a large graph quantum can dominate delay.
- Large or growing packet-gap/underrun counts mean the link or scheduling needs attention.

Audio is 48 kHz mono signed 16-bit PCM (~0.82 Mbit/s including protocol headers,
before UDP/IP/Wi-Fi overhead). Packet loss is concealed with silence for short gaps;
there is no retransmission or FEC. Reordered packets arriving after concealment are
dropped. The design prioritizes bounded delay over perfect playback on a poor link.

## Development and validation

The shared protocol, FIFO, packet loss/sequence wrap handling, and ±200 ppm clock
drift simulations can be tested on macOS or Linux without audio hardware:

```sh
cmake -S . -B build/core -DPHONEMIC_BUILD_RECEIVER=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build build/core --parallel
ctest --test-dir build/core --output-on-failure
python -m venv .venv
.venv/bin/pip install -r tools/requirements.txt
.venv/bin/python -m unittest discover -s tools -p 'test_*.py' -v
```

Unsigned iOS compilation:

```sh
xcodebuild -project ios/PhoneMic.xcodeproj -scheme PhoneMic -sdk iphoneos \
  -configuration Debug -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO build
```

CI builds the Linux receiver against actual PipeWire headers and runs the portable
core and signal-detection tests. Hardware capture, background behavior, PipeWire
routing, and achieved latency still require a real iPhone + Linux test.

## Transport and privacy

Pairing uses a random 64-bit bearer code printed by the receiver. Valid traffic
locks the receiver to one sender endpoint until it has been idle for three seconds.
The code filters accidental/unauthorized LAN senders; **it is sent in plaintext and
is not encryption or cryptographic message authentication**. Use a trusted LAN.
The app uses direct IPv4 UDP bound to the phone's Wi-Fi interface, with manual
address entry. No discovery service, internet relay, analytics, or audio storage.

See [docs/protocol.md](docs/protocol.md) for the wire format.

Implementation references: [Apple RemoteIO input callback](https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_setinputcallback),
[Apple hardware I/O preferences](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferrediobufferduration(_:)),
[PipeWire source streams](https://pipewire.pages.freedesktop.org/pipewire/page_streams.html),
[PortAudio callback timing](https://files.portaudio.com/docs/v19-doxydocs/structPaStreamCallbackTimeInfo.html).
