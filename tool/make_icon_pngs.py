#!/usr/bin/env python3
"""Draws the app icon's PNGs from its vector drawable. Needs Python 3 with
Pillow 9.1 or newer; runs from any folder.

  tool/make_icon_pngs.py
      Writes the PNG icons from the adaptive icon's layers (the colour
      ic_launcher_background and drawable/ic_launcher_foreground.xml): the
      launcher icons for Android 7 (mipmap-*dpi/ic_launcher.png, which have
      no adaptive icons) and the store icon
      (fastlane/metadata/android/en-US/images/icon.png). Each is the icon
      cut to a circle 44/48 of its width (Material's keyline for a round
      icon), on transparency. Run it after changing either layer. A PNG
      that already shows exactly this picture is left as it is.

  tool/make_icon_pngs.py --check
      Draws them again and fails, naming them, if the files show anything
      else, are missing, can't be read, have other sizes, or aren't written
      as the tool writes them (8-bit RGBA, no metadata).

It draws only what the vector drawable can say with absolute M, L, C and Z
path commands, each subpath a simple loop (not crossing itself), fill
colours with alpha, fillAlpha and fillType; anything else (groups, clip
paths, strokes, ...) stops it, so the PNGs can't silently differ from what
Android draws.
Shapes are drawn 8 times as big and scaled down, which smooths their edges.
"""

import math
import os
import pathlib
import re
import sys
import xml.etree.ElementTree as ET
import zlib

try:
    import PIL
    from PIL import Image, ImageChops, ImageDraw
except ImportError:
    sys.exit('tool/make_icon_pngs.py needs Pillow 9.1 or newer (on Debian or Ubuntu: python3-pil).')
if tuple(map(int, re.findall(r'\d+', PIL.__version__)[:2])) < (9, 1):
    sys.exit(f'tool/make_icon_pngs.py needs Pillow 9.1 or newer, not {PIL.__version__}.')

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / 'android/app/src/main/res'
BACKGROUND = RES / 'values/ic_launcher_background.xml'
FOREGROUND = RES / 'drawable/ic_launcher_foreground.xml'

# The PNGs: path, and width (= height) in pixels. A launcher icon is 48 dp.
# (test/app_icon_test.dart has the same list.)
PNGS = [
    (RES / 'mipmap-mdpi/ic_launcher.png', 48),
    (RES / 'mipmap-hdpi/ic_launcher.png', 72),
    (RES / 'mipmap-xhdpi/ic_launcher.png', 96),
    (RES / 'mipmap-xxhdpi/ic_launcher.png', 144),
    (RES / 'mipmap-xxxhdpi/ic_launcher.png', 192),
    (ROOT / 'fastlane/metadata/android/en-US/images/icon.png', 512),
]

ANDROID = '{http://schemas.android.com/apk/res/android}'

# An adaptive icon's layers are 108 x 108 dp; a launcher shows at most the
# middle 72 dp. The round icon is that circle, 44/48 of the PNG's width.
CANVAS = 108
VISIBLE = 72
KEYLINE = 44 / 48

SUPERSAMPLE = 8
CUBIC_STEPS = 32


class Unsupported(Exception):
    pass


def attr(element, name):
    return element.get(ANDROID + name)


def required(element, name, where):
    value = attr(element, name)
    if value is None:
        raise Unsupported(f'{where}: <{element.tag}> without android:{name}')
    return value


def parse_colour(text, where):
    """#RRGGBB or #AARRGGBB as (r, g, b, a), each 0..255."""
    match = re.fullmatch(r'#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})', text or '')
    if not match:
        raise Unsupported(f'{where}: colour {text!r} (only #RRGGBB or #AARRGGBB)')
    digits = match.group(1)
    if len(digits) == 6:
        digits = 'FF' + digits
    a, r, g, b = (int(digits[i:i + 2], 16) for i in range(0, 8, 2))
    return r, g, b, a


def background_colour():
    root = ET.parse(BACKGROUND).getroot()
    for colour in root.iter('color'):
        if colour.get('name') == 'ic_launcher_background':
            return parse_colour((colour.text or '').strip(), str(BACKGROUND))
    raise Unsupported(f'{BACKGROUND}: no colour ic_launcher_background')


NUMBER = r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?'


def parse_path(data, where):
    """The subpaths of path data, each a list of points with its cubics cut
    into lines. Each subpath is closed (a fill closes it anyway)."""
    tokens = re.findall(rf'[A-Za-z]|{NUMBER}', data)
    if re.sub(rf'[A-Za-z]|{NUMBER}|[\s,]', '', data):
        raise Unsupported(f'{where}: path data {data!r} has something else in it')
    subpaths, points, i = [], None, 0

    def numbers(count):
        nonlocal i
        values = tokens[i:i + count]
        if len(values) != count or any(re.fullmatch(r'[A-Za-z]', v) for v in values):
            raise Unsupported(f'{where}: a command is missing numbers')
        i += count
        return [float(v) for v in values]

    while i < len(tokens):
        command = tokens[i]
        i += 1
        if command not in 'MLCZ':
            raise Unsupported(f'{where}: path command {command!r} (only absolute M, L, C, Z)')
        if command == 'M':
            if points:
                subpaths.append(points)
            points = [tuple(numbers(2))]
        elif points is None:
            raise Unsupported(f'{where}: each subpath must start with M')
        elif command == 'L':
            points.append(tuple(numbers(2)))
        elif command == 'C':
            x1, y1, x2, y2, x, y = numbers(6)
            x0, y0 = points[-1]
            for step in range(1, CUBIC_STEPS + 1):
                t = step / CUBIC_STEPS
                u = 1 - t
                points.append((
                    u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x,
                    u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y,
                ))
        else:  # Z
            subpaths.append(points)
            points = None
        # Further numbers after a command repeat it: not used here.
        if i < len(tokens) and not re.fullmatch(r'[A-Za-z]', tokens[i]):
            raise Unsupported(f'{where}: numbers after {command!r} without a command')
    if points:
        subpaths.append(points)
    return subpaths


def signed_area(points):
    return sum(x0 * y1 - x1 * y0 for (x0, y0), (x1, y1) in zip(points, points[1:] + points[:1])) / 2


def orientation(a, b, c):
    turn = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    return 0 if abs(turn) < 1e-12 else (1 if turn > 0 else -1)


def segments_meet(a, b, c, d):
    """Whether the segments ab and cd cross or touch."""
    o1, o2, o3, o4 = orientation(a, b, c), orientation(a, b, d), orientation(c, d, a), orientation(c, d, b)
    if o1 != o2 and o3 != o4:
        return True

    def within(p, q, r):  # r, on the line pq, is between p and q
        return min(p[0], q[0]) <= r[0] <= max(p[0], q[0]) and min(p[1], q[1]) <= r[1] <= max(p[1], q[1])

    return ((o1 == 0 and within(a, b, c)) or (o2 == 0 and within(a, b, d))
            or (o3 == 0 and within(c, d, a)) or (o4 == 0 and within(c, d, b)))


def check_simple(subpaths, where):
    """Stops on a subpath that crosses or touches itself, or has no area:
    filling one takes real winding numbers, which fill_mask doesn't count."""
    for points in subpaths:
        loop = [p for i, p in enumerate(points) if p != points[i - 1]]
        if len(loop) < 3 or abs(signed_area(loop)) < 1e-9:
            raise Unsupported(f'{where}: a subpath with no area')
        edges = list(zip(loop, loop[1:] + loop[:1]))
        boxes = [(min(p[0], q[0]), min(p[1], q[1]), max(p[0], q[0]), max(p[1], q[1])) for p, q in edges]
        for i in range(len(edges)):
            for j in range(i + 2, len(edges) - (1 if i == 0 else 0)):
                bi, bj = boxes[i], boxes[j]
                if bi[2] < bj[0] or bj[2] < bi[0] or bi[3] < bj[1] or bj[3] < bi[1]:
                    continue
                if segments_meet(*edges[i], *edges[j]):
                    raise Unsupported(f'{where}: a subpath crosses or touches itself')


def fill_mask(subpaths, even_odd, size, transform):
    """A mask, 255 inside the path (by its fill rule) and 0 outside.

    Counts each subpath as a simple loop (check_simple): it adds 1 or takes
    1 from the winding number inside it, by which way round it runs."""
    counts = Image.new('L', size, 128)
    parity = Image.new('1', size, 0)
    for points in subpaths:
        loop = Image.new('L', size, 0)
        ImageDraw.Draw(loop).polygon([transform(p) for p in points], fill=1)
        if even_odd:
            parity = ImageChops.logical_xor(parity, loop.point(lambda v: 255 if v else 0).convert('1'))
        elif signed_area(points) > 0:
            counts = ImageChops.add(counts, loop)
        else:
            counts = ImageChops.subtract(counts, loop)
    if even_odd:
        return parity.convert('L')
    return counts.point(lambda v: 0 if v == 128 else 255)


def vector_path(element, where):
    subpaths = parse_path(required(element, 'pathData', where), where)
    check_simple(subpaths, where)
    return subpaths


def check_attributes(element, allowed, where):
    for name in element.attrib:
        local = name.replace(ANDROID, 'android:')
        if local not in allowed:
            raise Unsupported(f'{where}: <{element.tag}> attribute {local}')


def load_vector(path):
    """The paths of the vector drawable at [path], checked to be only what
    this tool draws: each (subpaths, (r, g, b), alpha, even_odd)."""
    root = ET.parse(path).getroot()
    where = str(path)
    if root.tag != 'vector':
        raise Unsupported(f'{where}: not a <vector>')
    check_attributes(root, {'android:width', 'android:height', 'android:viewportWidth',
                            'android:viewportHeight'}, where)
    for name in ('viewportWidth', 'viewportHeight'):
        if float(required(root, name, where)) != CANVAS:
            raise Unsupported(f'{where}: {name} is not {CANVAS}')
    for name in ('width', 'height'):
        if attr(root, name) != f'{CANVAS}dp':
            raise Unsupported(f'{where}: {name} is not {CANVAS}dp')
    paths = []
    for child in root:
        if child.tag != 'path':
            raise Unsupported(f'{where}: <{child.tag}>')
        if len(child):
            # Say an <aapt:attr> with a gradient instead of the fill colour.
            raise Unsupported(f'{where}: <path> with <{child[0].tag}> in it')
        check_attributes(child, {'android:name', 'android:pathData', 'android:fillColor',
                                 'android:fillAlpha', 'android:fillType'}, where)
        r, g, b, a = parse_colour(required(child, 'fillColor', where), where)
        fill_type = attr(child, 'fillType') or 'nonZero'
        if fill_type not in ('nonZero', 'evenOdd'):
            raise Unsupported(f'{where}: fillType {fill_type}')
        paths.append((vector_path(child, where), (r, g, b),
                      a * float(attr(child, 'fillAlpha') or 1), fill_type == 'evenOdd'))
    return paths


def draw(canvas, paths, transform, clip):
    """Draws [paths] (from load_vector) onto [canvas] (RGBA), inside the
    mask [clip]."""
    for subpaths, (r, g, b), alpha, even_odd in paths:
        mask = ImageChops.multiply(fill_mask(subpaths, even_odd, canvas.size, transform), clip)
        layer = Image.new('RGBA', canvas.size, (r, g, b, 0))
        layer.putalpha(mask.point(lambda v: round(v * alpha / 255)))
        canvas.alpha_composite(layer)


def render(size, background, foreground):
    """The round icon, [size] pixels wide: the [background] colour and the
    [foreground] paths, cut to a circle of 44/48 of the width."""
    big = size * SUPERSAMPLE
    scale = big * KEYLINE / VISIBLE
    offset = big / 2 - CANVAS / 2 * scale

    def transform(point):
        x, y = point
        return (offset + x * scale, offset + y * scale)

    steps = 1440
    circle = fill_mask([[
        (CANVAS / 2 + VISIBLE / 2 * math.cos(2 * math.pi * i / steps),
         CANVAS / 2 + VISIBLE / 2 * math.sin(2 * math.pi * i / steps))
        for i in range(steps)
    ]], False, (big, big), transform)
    canvas = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    r, g, b, a = background
    layer = Image.new('RGBA', (big, big), (r, g, b, 0))
    layer.putalpha(circle.point(lambda v: round(v * a / 255)))
    canvas.alpha_composite(layer)
    draw(canvas, foreground, transform, circle)
    # Scale down with premultiplied alpha, or the transparent black around
    # the circle would darken its edge.
    return canvas.convert('RGBa').resize((size, size), Image.Resampling.BOX).convert('RGBA')


def file_problems(path):
    """What in the PNG file at [path] isn't as this tool writes it: whole,
    with every chunk's CRC right and nothing after the end, 8-bit RGBA, not
    interlaced, and only the image (no metadata)."""
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        return ['not a PNG file']
    chunks, header, at = [], None, 8
    while at + 12 <= len(data):
        length = int.from_bytes(data[at:at + 4], 'big')
        kind = data[at + 4:at + 8]
        name = kind.decode('latin-1')
        if at + 12 + length > len(data):
            return [f'chunk {name} is cut off']
        body = data[at + 8:at + 8 + length]
        if zlib.crc32(kind + body) != int.from_bytes(data[at + 8 + length:at + 12 + length], 'big'):
            return [f'chunk {name} is damaged']
        chunks.append(name)
        if name == 'IHDR':
            header = body
        at += 12 + length
        if name == 'IEND':
            break
    problems = []
    if at != len(data) or not chunks or chunks[0] != 'IHDR' or chunks[-1] != 'IEND':
        problems.append('not one whole PNG image')
    if header is None or len(header) != 13 or header[8:10] != b'\x08\x06' or header[12] != 0:
        problems.append('not 8-bit RGBA without interlacing')
    others = sorted(set(chunks) - {'IHDR', 'IDAT', 'IEND'})
    if others:
        problems.append(f'has more than the image: {", ".join(others)}')
    return problems


def differences(image, path):
    """Why the PNG at [path] isn't [image], written as this tool writes it;
    empty if it is."""
    if not path.exists():
        return ['missing']
    try:
        problems = file_problems(path)
        if problems:
            return problems
        with Image.open(path) as saved:
            saved.load()
            if saved.size != image.size:
                return [f'{saved.size[0]} x {saved.size[1]}, not {image.size[0]} x {image.size[1]}']
            # Premultiplied: the colour of a transparent pixel doesn't show.
            diff = ImageChops.difference(saved.convert('RGBA').convert('RGBa'), image.convert('RGBa'))
    except Exception as error:  # Whatever Pillow raises for a file it can't read.
        return [f"can't be read ({error})"]
    largest = max(high for _, high in diff.getextrema())
    if largest:
        return [f'differs by up to {largest} in a colour channel']
    return []


def write(image, path):
    """Writes [image] to [path] whole or not at all: to a temporary file
    first, which then takes its place."""
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + '.partial')
    try:
        # No metadata: Pillow adds none unless asked.
        image.save(partial, format='PNG', optimize=True)
        os.replace(partial, path)
    finally:
        partial.unlink(missing_ok=True)


def main(argv):
    if argv not in ([], ['--check']):
        sys.exit(__doc__)
    check = argv == ['--check']
    try:
        background = background_colour()
        foreground = load_vector(FOREGROUND)
        # All drawn before any is written, so a drawing error writes none.
        images = [(path, size, render(size, background, foreground)) for path, size in PNGS]
    except (Unsupported, ET.ParseError, OSError, ValueError) as error:
        sys.exit(f"Can't draw the icon: {error}")
    failed = []
    for path, size, image in images:
        name = path.relative_to(ROOT)
        problems = differences(image, path)
        if check:
            failed += [f'{name}: {problem}' for problem in problems]
        elif problems:
            try:
                write(image, path)
            except OSError as error:
                sys.exit(f"Can't write {name}: {error}")
            print(f'Wrote {name} ({size} x {size})')
        else:
            print(f'Kept {name} (the same picture)')
    if failed:
        sys.exit('The icon PNGs differ from the vector icon (run tool/make_icon_pngs.py):\n'
                 + '\n'.join(f'  {line}' for line in failed))
    if check:
        print('The icon PNGs match the vector icon.')


if __name__ == '__main__':
    main(sys.argv[1:])
