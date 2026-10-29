# PhoneMic UDP v1

One sender, one receiver, default IPv4 UDP port 5555. No connection negotiation.
All multibyte **header and status integers are big-endian**. PCM payload is
**little-endian signed 16-bit mono, 48,000 Hz**, with exactly 240 samples per packet.
No native structs are sent over the wire.

| Offset | Bytes | Field |
| --- | --- | --- |
| 0 | 4 | ASCII `PMIC` |
| 4 | 1 | Version, `1` |
| 5 | 1 | Type: audio `1`, ping `2`, pong `3` |
| 6 | 2 | Sample count: `240` for audio, `0` otherwise |
| 8 | 8 | Pairing bearer token |
| 16 | 4 | Audio sequence, increments per 5 ms packet, wraps modulo 2³² |
| 20 | 4 | Sample rate, `48000` |
| 24 | 8 | Sender monotonic nanoseconds; echoed unchanged by pong |

Audio datagram: 512 bytes (32-byte header, 480-byte PCM payload). Ping: 32 bytes.
Pong: 56 bytes, header plus six uint32 counters:

| Offset | Field |
| --- | --- |
| 32 | Current receiver queue in 48 kHz frames |
| 36 | Receiver underflow events |
| 40 | Missing packets inferred from sequence gaps |
| 44 | Late/duplicate packets dropped |
| 48 | Most recently requested PipeWire callback frame count |
| 52 | Accepted audio packets |

The sender pings every 500 ms and measures elapsed time using its own clock. No
cross-device clock subtraction or one-way transit claim is made. Header time on an
audio packet describes packet assembly, not the microphone ADC timestamp.

Malformed, oversized, unsupported-rate/version/type, wrong-token, and wrong-size
datagrams are discarded. A paired endpoint is held until three seconds without
valid traffic. A newly accepted endpoint resets sequence expectations. Counters
are cumulative for the receiver process, including across reconnects, and wrap at
32 bits. Sample storage is SPSC: producer never overwrites unread data; consumer
sheds excessive backlog. The consumer primes to jitter target plus one requested
render block, and outputs silence while waiting. Short network gaps (up to four
packets) insert silence; larger ones skip forward without inserting a long delay.
Subsequent late packets are discarded. Very large graph quanta can exceed the
target latency; inspect the actual quantum.

The bearer code is visible to anyone who can observe LAN packets. This protocol
has no encryption, authenticated packet integrity, replay protection, discovery,
FEC, or retransmission. Do not expose the receiver on an untrusted network.
