import socket
import struct
import threading
import unittest

from probe_receiver import probe


class ProbeTests(unittest.TestCase):
    def test_udp_round_trip_ignores_unrelated_replies(self):
        token = 0x0123456789ABCDEF
        failures = []
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
            server.bind(("127.0.0.1", 0))
            server.settimeout(2)

            def receive():
                try:
                    packet, peer = server.recvfrom(1024)
                    # Verify wire bytes against the protocol, not Python's unpacker.
                    self.assertEqual(packet[:24], bytes.fromhex(
                        "504d4943 01 02 0000 0123456789abcdef 00000000 0000bb80"))
                    response = bytearray(packet)
                    response[5] = 3
                    response.extend(struct.pack("!6I", 480, 1, 2, 3, 128, 999))
                    server.sendto(b"malformed", peer)
                    wrong_code = bytearray(response)
                    wrong_code[8] ^= 1
                    server.sendto(wrong_code, peer)
                    stale = bytearray(response)
                    stale[31] ^= 1
                    server.sendto(stale, peer)
                    server.sendto(response, peer)
                except Exception as exc:
                    failures.append(exc)

            worker = threading.Thread(target=receive)
            worker.start()
            try:
                result = probe("127.0.0.1", server.getsockname()[1], token)
            finally:
                worker.join(3)
            self.assertFalse(worker.is_alive())
            if failures:
                raise failures[0]
            self.assertEqual(result["queue_ms"], 10)
            self.assertEqual(result["quantum"], 128)
            self.assertEqual(result["audio_packets"], 999)

    def test_listening_socket_without_valid_reply_times_out(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
            server.bind(("127.0.0.1", 0))
            with self.assertRaises(TimeoutError):
                probe("127.0.0.1", server.getsockname()[1], 1, timeout=0.05)


if __name__ == "__main__":
    unittest.main()
