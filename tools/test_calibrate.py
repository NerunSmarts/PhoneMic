import unittest
import numpy as np
from calibrate import RATE, chirp, detect


class CalibrationTests(unittest.TestCase):
    def test_known_delay_with_noise_and_polarity_inversion(self):
        rng = np.random.default_rng(123)
        probe = chirp()
        starts = [RATE, 2 * RATE, 3 * RATE]
        recording = rng.normal(0, 0.002, 5 * RATE).astype(np.float32)
        delay = 1872  # 39 ms
        for start in starts:
            recording[start + delay:start + delay + len(probe)] -= probe * 0.08
        results = detect(recording, probe, starts)
        self.assertTrue(all(r["valid"] for r in results))
        self.assertTrue(all(abs(r["latency_ms"] - 39) < 0.05 for r in results))

    def test_silence_and_unrelated_noise_are_rejected(self):
        probe = chirp()
        silence = np.zeros(3 * RATE, dtype=np.float32)
        self.assertFalse(detect(silence, probe, [RATE])[0]["valid"])
        noise = np.random.default_rng(0).normal(0, 0.1, 3 * RATE).astype(np.float32)
        self.assertFalse(detect(noise, probe, [RATE])[0]["valid"])

    def test_equal_echoes_are_ambiguous(self):
        probe = chirp()
        recording = np.zeros(3 * RATE, dtype=np.float32)
        for delay in [1000, 5000]:
            recording[RATE + delay:RATE + delay + len(probe)] = probe
        self.assertFalse(detect(recording, probe, [RATE])[0]["valid"])


if __name__ == "__main__":
    unittest.main()
