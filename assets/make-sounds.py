#!/usr/bin/env python3
"""Synthesizes the two soft chimes (stdlib only): python3 assets/make-sounds.py

focus-done.wav  descending E6 → B5 → E5: "time to rest"
break-done.wav  ascending  E5 → B5 → E6: "back to it"
"""
import math
import os
import struct
import wave

RATE = 44100
HERE = os.path.dirname(os.path.abspath(__file__))

# Partials of a soft glass/bell tone: (ratio, amplitude, decay seconds).
PARTIALS = [(1.0, 1.0, 0.95), (2.0, 0.28, 0.45), (2.76, 0.10, 0.30), (5.40, 0.04, 0.12)]


def note(freq, start, length, gain, buf):
    attack = 0.006
    for i in range(int(length * RATE)):
        t = i / RATE
        env_a = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / attack))
        v = 0.0
        for ratio, amp, decay in PARTIALS:
            v += amp * math.exp(-t / decay) * math.sin(2 * math.pi * freq * ratio * t)
        j = int(start * RATE) + i
        if j < len(buf):
            buf[j] += gain * env_a * v


def render(name, freqs, gap=0.16, total=1.9):
    buf = [0.0] * int(total * RATE)
    for k, f in enumerate(freqs):
        note(f, k * gap, total - k * gap, 0.9 - 0.12 * k, buf)
    peak = max(abs(x) for x in buf) or 1.0
    scale = 0.5 / peak  # about -6 dBFS: present but not harsh
    fade = int(0.08 * RATE)
    for i in range(fade):
        buf[-1 - i] *= i / fade
    with wave.open(os.path.join(HERE, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, x * scale)) * 32767)) for x in buf))
    print("wrote", name)


E5, B5, E6 = 659.25, 987.77, 1318.51
render("focus-done.wav", [E6, B5, E5])
render("break-done.wav", [E5, B5, E6])
