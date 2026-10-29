#!/usr/bin/env python3
"""Vergleicht zwei Bilder (beliebige Formate, über sips auf 120×W skaliert) und gibt die mittlere
Abweichung pro Farbkanal aus (0 = gleich, 255 = völlig anders). Nur macOS (sips)."""
import os, struct, subprocess, sys, tempfile

def load(path, width=120):
    out = tempfile.mktemp(suffix=".bmp")
    subprocess.run(["sips", "-s", "format", "bmp", "--resampleWidth", str(width), path, "--out", out],
                   check=True, capture_output=True)
    data = open(out, "rb").read()
    os.remove(out)
    offset = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0] // 8
    row = (w * bpp + 3) // 4 * 4
    pixels = []
    for y in range(abs(h)):
        base = offset + y * row
        for x in range(w):
            p = base + x * bpp
            pixels.append(data[p:p + 3])
    return abs(h), pixels

h1, a = load(sys.argv[1])
h2, b = load(sys.argv[2])
n = min(len(a), len(b))
diff = sum(abs(a[i][c] - b[i][c]) for i in range(n) for c in range(3)) / (3 * n)
print(f"{diff:.1f} {h1} {h2}")
