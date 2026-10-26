"""Reading and writing 8-bit PNGs (RGB or RGBA, not interlaced) with the standard library only."""
import struct
import zlib


def read(path):
    """-> (width, height, rows): rows of (r, g, b, a) tuples."""
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', path
    at, idat = 8, b''
    while at < len(data):
        n, kind = struct.unpack('>I4s', data[at:at + 8])
        body = data[at + 8:at + 8 + n]
        at += 12 + n
        if kind == b'IHDR':
            w, h, depth, color, _, _, interlace = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
    assert depth == 8 and interlace == 0 and color in (2, 6), (depth, color, interlace)
    ch = 3 if color == 2 else 4
    raw, stride, rows, prev, p = zlib.decompress(idat), w * ch, [], bytearray(w * ch), 0
    for _ in range(h):
        f, line = raw[p], bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            c = prev[x - ch] if x >= ch else 0
            b = prev[x]
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                q = a + b - c
                pa, pb, pc = abs(q - a), abs(q - b), abs(q - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append([tuple(line[x * ch:x * ch + ch]) + ((255,) if ch == 3 else ()) for x in range(w)])
        prev = line
    return w, h, rows


def write(path, rows):
    """rows of (r, g, b, a) tuples -> an RGBA PNG."""
    h, w = len(rows), len(rows[0])
    raw = b''.join(b'\0' + bytes(v for px in r for v in px) for r in rows)

    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xFFFFFFFF)

    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def shrink(rows, size):
    """A square RGBA image box-filtered to size x size (colours weighted by alpha)."""
    n = len(rows)
    out = []
    for oy in range(size):
        y0, y1 = oy * n / size, (oy + 1) * n / size
        line = []
        for ox in range(size):
            x0, x1 = ox * n / size, (ox + 1) * n / size
            acc = [0.0, 0.0, 0.0, 0.0]
            area = 0.0
            for y in range(int(y0), min(n, int(y1 + 0.9999))):
                wy = min(y + 1, y1) - max(y, y0)
                for x in range(int(x0), min(n, int(x1 + 0.9999))):
                    wgt = wy * (min(x + 1, x1) - max(x, x0))
                    r, g, b, a = rows[y][x]
                    acc[0] += r * a * wgt
                    acc[1] += g * a * wgt
                    acc[2] += b * a * wgt
                    acc[3] += a * wgt
                    area += wgt
            a = acc[3] / area
            line.append(tuple(int(round(acc[i] / acc[3])) if acc[3] else 0 for i in range(3)) + (int(round(a)),))
        out.append(line)
    return out
