# Text to SVG path: shape with HarfBuzz (kerning, variable axes), outline with the same font.
import os
import uharfbuzz as hb
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.basePen import decomposeQuadraticSegment

FONT_DIR = os.environ.get('FONT_DIR', os.path.join(os.path.dirname(__file__), '..', 'fonts'))
_cache = {}

def _font(file, axes):
    key = (file, tuple(sorted((axes or {}).items())))
    if key not in _cache:
        blob = hb.Blob.from_file_path(os.path.join(FONT_DIR, file))
        face = hb.Face(blob)
        font = hb.Font(face)
        if axes:
            font.set_variations(axes)
        _cache[key] = (font, face.upem)
    return _cache[key]

def shape(text, file, axes=None, features=None):
    font, upem = _font(file, axes)
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(font, buf, features or {})
    return font, upem, buf.glyph_infos, buf.glyph_positions

def width(text, file, size, axes=None, track=0):
    _, upem, infos, pos = shape(text, file, axes)
    s = size / upem
    return sum(p.x_advance for p in pos) * s + track * max(len(infos) - 1, 0)

def ink_box(text, file, size, axes=None, track=0):
    """Tight bounds of the drawn glyphs, relative to the pen origin on the baseline (y down)."""
    font, upem, infos, pos = shape(text, file, axes)
    s = size / upem
    x = 0; xs = []; ys = []
    for i, p in zip(infos, pos):
        e = font.get_glyph_extents(i.codepoint)
        if e and e.width:
            gx = x + p.x_offset * s
            xs += [gx + e.x_bearing * s, gx + (e.x_bearing + e.width) * s]
            ys += [-(e.y_bearing) * s, -(e.y_bearing + e.height) * s]
        x += p.x_advance * s + track
    if not xs:
        return 0, 0, 0, 0
    return min(xs), min(ys), max(xs), max(ys)

def path(text, file, size, x, y, axes=None, track=0, skew=0):
    """SVG path data for text whose baseline starts at (x, y). skew: fake-oblique angle factor (tan)."""
    font, upem, infos, pos = shape(text, file, axes)
    s = size / upem
    pen = RecordingPen()
    cx = x
    for i, p in zip(infos, pos):
        ox = cx + p.x_offset * s
        oy = y - p.y_offset * s
        tp = TransformPen(pen, (s, 0, skew * s, -s, ox, oy))
        font.draw_glyph_with_pen(i.codepoint, tp)
        cx += p.x_advance * s + track
    return compact(pen.value)

def _n(v):
    t = ('%.1f' % v).rstrip('0').rstrip('.')
    if t in ('-0', ''): t = '0'
    return t.replace('0.', '.', 1) if t.startswith('0.') else ('-' + t[2:] if t.startswith('-0.') else t)

def _join(nums):
    out = ''
    for t in nums:
        out += t if (not out or t[0] == '-' or (t[0] == '.' and '.' in out.split(' ')[-1].lstrip('-').split('-')[-1])) else ' ' + t
    return out

def compact(ops):
    """Relative, 0.1-unit path data. Rounding is done on absolute points so errors never accumulate.
    Repeated commands drop their letter; axis-aligned lines use h / v."""
    R = lambda pt: (round(pt[0], 1), round(pt[1], 1))
    segs = []; cur = (0.0, 0.0); start = None
    for op, args in ops:
        if op == 'moveTo':
            p = R(args[0])
            segs.append(('M', [p[0], p[1]]) if start is None else ('m', [p[0]-cur[0], p[1]-cur[1]]))
            cur = start = p
        elif op == 'lineTo':
            p = R(args[0]); dx, dy = p[0]-cur[0], p[1]-cur[1]
            if abs(dy) < 0.05: segs.append(('h', [dx]))
            elif abs(dx) < 0.05: segs.append(('v', [dy]))
            else: segs.append(('l', [dx, dy]))
            cur = p
        elif op == 'curveTo':
            pts = [R(a) for a in args]
            segs.append(('c', [v for q in pts for v in (q[0]-cur[0], q[1]-cur[1])])); cur = pts[-1]
        elif op == 'qCurveTo':
            for c1, e in decomposeQuadraticSegment(list(args)):
                c1, e = R(c1), R(e)
                segs.append(('q', [c1[0]-cur[0], c1[1]-cur[1], e[0]-cur[0], e[1]-cur[1]])); cur = e
        elif op in ('closePath', 'endPath'):
            segs.append(('z', [])); cur = start
    out = []; last = None
    for cmd, nums in segs:
        t = _join([_n(v) for v in nums])
        if cmd == last and cmd not in ('z', 'M', 'm'):
            out.append(t if t[0] == '-' else ' ' + t)
        else:
            out.append(cmd + t)
        last = cmd
    return ''.join(out)
