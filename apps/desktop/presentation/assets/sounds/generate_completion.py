"""Render Mokaid's original, gentle completion chime (no external samples)."""

from math import cos, exp, pi, sin
from pathlib import Path
import struct
import wave


def render() -> None:
    rate = 44_100
    duration = 1.25
    # A warm A-major voicing; the short ascending gesture resolves softly.
    notes = ((0.0, 440.0, 0.48), (0.12, 554.365, 0.38), (0.24, 659.255, 0.34))
    samples = []
    for frame in range(round(rate * duration)):
        time = frame / rate
        value = 0.0
        for start, frequency, level in notes:
            age = time - start
            if age < 0:
                continue
            attack = min(1.0, age / 0.022)
            envelope = (0.5 - 0.5 * cos(pi * attack)) * exp(-age / 0.22)
            # A restrained second partial adds a rounded wooden-mallet character.
            tone = sin(2 * pi * frequency * age)
            tone += 0.12 * sin(4 * pi * frequency * age) * exp(-age / 0.11)
            value += level * envelope * tone
        # Finish at exact silence, so stop/replay cannot click at the file boundary.
        fade = min(1.0, max(0.0, (duration - time - 1 / rate) / 0.18))
        samples.append(value * (0.5 - 0.5 * cos(pi * fade)))

    gain = 0.5 / max(abs(value) for value in samples)  # -6 dBFS peak headroom.
    pcm = b"".join(struct.pack("<h", round(value * gain * 32767)) for value in samples)
    with wave.open(str(Path(__file__).with_name("mission-complete.wav")), "wb") as output:
        output.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        output.writeframes(pcm)


if __name__ == "__main__":
    render()
