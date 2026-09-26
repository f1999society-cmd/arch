#!/usr/bin/env python3
"""Convert QEMU screendump PPM (P6) files to PNG using only the stdlib.

QEMU's HMP 'screendump' writes binary PPM; GitHub artifact previews (and
humans) want PNG. The CI container has python but not Pillow, so we emit a
minimal valid PNG: 8-bit RGB, one filter byte (0) per scanline, zlib 'deflate'
IDAT. Handles QEMU's header style ('P6\n< w> <h>\n255\n') plus comments and
loose whitespace, which the PPM spec allows.
"""
import sys
import struct
import zlib


def ppm_to_png(path: str) -> bool:
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except OSError:
        return False
    if not data.startswith(b'P6'):
        return False

    idx = 2
    fields: list[bytes] = []
    while len(fields) < 3 and idx < len(data):
        # skip whitespace
        while idx < len(data) and data[idx: idx + 1] in b' \t\r\n':
            idx += 1
        # skip '#' comments to end of line
        if idx < len(data) and data[idx: idx + 1] == b'#':
            while idx < len(data) and data[idx: idx + 1] not in b'\r\n':
                idx += 1
            continue
        j = idx
        while j < len(data) and data[j: j + 1] not in b' \t\r\n':
            j += 1
        if j == idx:
            break
        fields.append(data[idx: j])
        idx = j
    if len(fields) < 3:
        return False
    try:
        w, h, maxv = int(fields[0]), int(fields[1]), int(fields[2])
    except ValueError:
        return False
    if w <= 0 or h <= 0 or not 1 <= maxv < 65536:
        return False

    idx += 1  # exactly one whitespace byte separates header from raster
    if maxv > 255:  # 2-byte samples unsupported by this minimal writer
        return False
    raw = data[idx: idx + w * h * 3]
    if len(raw) < w * h * 3:
        return False

    stride = w * 3
    scanlines = b''.join(b'\x00' + raw[y * stride: (y + 1) * stride] for y in range(h))

    def chunk(ctype: bytes, payload: bytes) -> bytes:
        return (struct.pack('>I', len(payload)) + ctype + payload
                + struct.pack('>I', zlib.crc32(ctype + payload) & 0xffffffff))

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(scanlines, 6))
           + chunk(b'IEND', b''))
    out = path[:-4] + '.png' if path.lower().endswith('.ppm') else path + '.png'
    try:
        with open(out, 'wb') as f:
            f.write(png)
    except OSError:
        return False
    return True


if __name__ == '__main__':
    rc = 0
    for p in sys.argv[1:]:
        ok = ppm_to_png(p)
        print(('ok   ' if ok else 'skip ') + p)
        rc |= 0 if ok else 1
    sys.exit(rc)
