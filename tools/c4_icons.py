"""Makes src/c4_deploy.png and src/c4_detonate.png, C4's two mode icons, from the game's HUD atlas.

    python tools/c4_icons.py <crop.png>

The icons are in the atlas texture 0x10a0814c0fad8650 (2048x1024, package packages/content/atlas_mission, archive
0xd88cc00669d53c0c); extract it with filediver:

    filediver.exe -a 0xd88cc00669d53c0c -i "0x10a0814c0fad8650*" -T texture --texture-format png -o <folder>

DETONATE (the toothed ring) is at x 1644-1717, y 620-692 and DEPLOY (an arrow over a charge) at x 1816-1864,
y 619-693 there (2 px of margin round each). <crop.png> is both side by side at 3x, as made from it: a 5 px border and
a 10 px gap on (60, 0, 60). The atlas has no alpha: the icon is white (R, G and B), its glow blue (B only). Here the
icon is cream, the glow a dark edge, on transparent; each is centred on a 76 x 76 square.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import png_rgba  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIZE = 76
INK = (250, 250, 236)
GLOW = 0.6                       # the glow's opacity, of its blue


def from_crop(path):
    w, h, rows = png_rgba.read(path)
    bg = (60, 0, 60, 255)
    cols = [x for x in range(w) if any(rows[y][x] != bg for y in range(h))]
    runs, start, last = [], cols[0], cols[0]
    for x in cols[1:]:
        if x != last + 1:
            runs.append((start, last))
            start = x
        last = x
    runs.append((start, last))
    icons = []
    for x0, x1 in runs:
        ys = [y for y in range(h) if any(rows[y][x] != bg for x in range(x0, x1 + 1))]
        y0 = ys[0]
        icons.append([[rows[y0 + y * 3 + 1][x0 + x * 3 + 1] for x in range((x1 - x0 + 1) // 3)]
                      for y in range((ys[-1] - y0 + 1) // 3)])
    return icons                 # [detonate, deploy]


def to_rgba(px):
    h, w = len(px), len(px[0])
    out = [[(0, 0, 0, 0)] * SIZE for _ in range(SIZE)]
    ox, oy = (SIZE - w) // 2, (SIZE - h) // 2
    for y in range(h):
        for x in range(w):
            r, g, b, _ = px[y][x]
            body = r / 255
            a = max(body, GLOW * b / 255)
            if a > 0:
                k = body / a
                out[oy + y][ox + x] = tuple(int(round(c * k)) for c in INK) + (int(round(a * 255)),)
    return out


if __name__ == '__main__':
    detonate, deploy = from_crop(sys.argv[1])
    for name, px in (('detonate', detonate), ('deploy', deploy)):
        png_rgba.write(os.path.join(HERE, 'src', 'c4_%s.png' % name), to_rgba(px))
        print('src/c4_%s.png from %d x %d' % (name, len(px[0]), len(px)))
