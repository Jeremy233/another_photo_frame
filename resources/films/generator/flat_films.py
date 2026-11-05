# Flat film icon draft, v2: one layout, colours and type character taken from each box.
# All lettering is converted to paths (open-licence fonts, see FONTS below), so the SVGs need no fonts.
# Usage, from resources/films:  FONT_DIR=<folder with the fonts listed in SOURCES.md> python3 generator/flat_films.py .
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from textpath import path, ink_box

OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
LINE_CAP = float(os.environ.get('LINE_CAP', 78))  # series name cap height
ISO_H = float(os.environ.get('ISO_H', 124))       # ISO number ink height
Y = '#F5B01A'   # Kodak yellow
FG = '#00AC4E'  # Fujifilm green, sampled from the official box images

# Type styles: font file, variable axes, tracking (em), fake-oblique (tan), extra stroke (em, faux bold)
T = {
 'thin-geo':   ('Jost[wght].ttf', {'wght': 300}, 0.02, 0, 0),         # Portra 160/400, Gold 200: Futura-light feel
 'hair-geo':   ('Jost[wght].ttf', {'wght': 250}, 0.0, 0, 0),          # CineStill numbers
 'geo-book':   ('Jost[wght].ttf', {'wght': 450}, 0.0, 0, 0),          # Velvia
 'didone':     ('BodoniModa[opsz,wght].ttf', {'opsz': 96, 'wght': 700}, -0.01, 0, 0),  # Portra 800 numerals
 'didone-cap': ('BodoniModa[opsz,wght].ttf', {'opsz': 28, 'wght': 500}, 0.22, 0, 0),   # Portra 800 spaced caps
 'heavy-serif':('Fraunces[SOFT,WONK,opsz,wght].ttf', {'opsz': 48, 'wght': 900, 'SOFT': 0, 'WONK': 0}, 0.0, 0, 0),  # Gold
 'cond-light': ('BarlowCondensed-Light.ttf', None, 0.0, 0, 0),         # Ektar
 'cond-med':   ('BarlowCondensed-Medium.ttf', None, 0.0, 0, 0),        # ProImage
 'cond-bold':  ('BarlowCondensed-Bold.ttf', None, 0.01, 0, 0),         # Fujifilm pro lines
 'cond-black': ('BarlowCondensed-ExtraBold.ttf', None, 0.0, 0, 0),     # Vision3 can labels
 'extended':   ('Michroma-Regular.ttf', None, -0.03, 0, 0.035),          # Ektachrome E100, bold extended
 'humanist':   ('SourceSans3[wght].ttf', {'wght': 600}, 0.04, 0, 0),   # EKTACHROME
 'geo-black':  ('Montserrat[wght].ttf', {'wght': 900}, -0.02, 0, 0),   # T-Max numbers
 'geo-bold':   ('Montserrat[wght].ttf', {'wght': 800}, 0.015, 0, 0),   # Tri-X numbers
 'wide-caps':  ('Archivo[wdth,wght].ttf', {'wdth': 125, 'wght': 700}, 0.2, 0, 0),   # T-MAX / TRI-X header
 'italic-blk': ('Archivo-Italic[wdth,wght].ttf', {'wdth': 112, 'wght': 900}, 0.0, 0, 0),  # UltraMax
 'italic-wide':('Archivo-Italic[wdth,wght].ttf', {'wdth': 125, 'wght': 800}, 0.0, 0, 0),  # CineStill names
 'grotesk':    ('Archivo[wdth,wght].ttf', {'wdth': 100, 'wght': 700}, 0.0, 0, 0),  # ColorPlus, consumer
 'grotesk-blk':('Archivo[wdth,wght].ttf', {'wdth': 112, 'wght': 900}, 0.0, 0, 0),  # Ilford
 'grotesk-cap':('Archivo[wdth,wght].ttf', {'wdth': 112, 'wght': 700}, 0.12, 0, 0), # VISION3, PAN, COLOR
}
UI_TAG = ('Archivo[wdth,wght].ttf', {'wdth': 100, 'wght': 600})
UI_BRAND = ('Archivo[wdth,wght].ttf', {'wdth': 112, 'wght': 800})

# name, id, brand, line text, line style, iso, iso style, process, bg, band, iso colour, line colour, effect
F = [
 ('Kodak Portra 160','kodak-portra-160','KODAK','PORTRA','thin-geo','160','thin-geo','C-41','#8E7CC3',Y,None,None,None),
 ('Kodak Portra 400','kodak-portra-400','KODAK','PORTRA','thin-geo','400','thin-geo','C-41','#7657A6',Y,None,None,None),
 ('Kodak Portra 800','kodak-portra-800','KODAK','PORTRA','didone-cap','800','didone','C-41','#5A5FB4',Y,None,None,None),
 ('Kodak Gold 200','kodak-gold-200','KODAK','GOLD','heavy-serif','200','thin-geo','C-41',Y,'#B4389A','#2A1A10','#2A1A10',None),
 ('Kodak Ektar 100','kodak-ektar-100','KODAK','Ektar','cond-light','100','cond-light','C-41','#E4532B',Y,None,None,None),
 ('Kodak ColorPlus 200','kodak-colorplus-200','KODAK','ColorPlus','grotesk','200','grotesk','C-41','#C9262F','#2A5DB0',None,None,None),
 ('Kodak Ultramax 400','kodak-ultramax-400','KODAK','ULTRAMAX','italic-blk','400','italic-blk','C-41','#2B5FAE',Y,None,None,None),
 ('Kodak ProImage 100','kodak-proimage-100','KODAK','Pro Image','cond-med','100','cond-med','C-41',Y,'#1A1A1A','#161616','#161616',None),
 ('Kodak Ektachrome E100','kodak-ektachrome-e100','KODAK','EKTACHROME','humanist','E100','extended','E-6','#1D4E9E',Y,None,None,None),
 ('Kodak T-Max 100','kodak-tmax-100','KODAK','T-MAX','wide-caps','100','geo-black','B&W','#151515',Y,'#9A5BC0',None,None),
 ('Kodak T-Max 400','kodak-tmax-400','KODAK','T-MAX','wide-caps','400','geo-black','B&W','#151515',Y,'#3BB27A',None,None),
 ('Kodak T-Max P3200','kodak-tmax-p3200','KODAK','T-MAX','wide-caps','P3200','geo-black','B&W','#151515',Y,None,None,None),
 ('Kodak Tri-X 320','kodak-trix-320','KODAK','TRI-X','wide-caps','320','geo-bold','B&W',Y,'#0E5A43','#0E5A43','#161616','extrude'),
 ('Kodak Tri-X 400','kodak-trix-400','KODAK','TRI-X','wide-caps','400','geo-bold','B&W',Y,'#0E5A43','#0E5A43','#161616','extrude'),
 ('Kodak Vision3 250D','kodak-vision3-250d','KODAK','VISION3','grotesk-cap','250D','cond-black','ECN-2','#3B4148','#E7A33C',None,None,None),
 ('Kodak Vision3 500T','kodak-vision3-500t','KODAK','VISION3','grotesk-cap','500T','cond-black','ECN-2','#22262B','#E7A33C',None,None,None),
 ('Fujifilm Velvia 50','fujifilm-velvia-50','FUJIFILM','Velvia','geo-book','50','cond-bold','E-6','#006DAB',FG,'#D4AC62','#D4AC62',None),
 ('Fujifilm Provia 100F','fujifilm-provia-100f','FUJIFILM','PROVIA','cond-bold','100F','cond-bold','E-6','#332E70',FG,None,None,None),
 ('Fujifilm Pro 400H','fujifilm-pro-400h','FUJIFILM','PRO','cond-bold','400H','cond-bold','C-41','#693084',FG,None,None,None),
 ('Fujifilm 400','fujifilm-400','FUJIFILM','COLOR','grotesk-cap','400','grotesk','C-41','#F3F3F1',FG,'#0088B8',None,None),
 ('Fujifilm C200','fujifilm-c200','FUJIFILM','FUJICOLOR','grotesk-cap','C200','grotesk','C-41','#F3F3F1',FG,'#B8509A',None,None),
 ('Ilford HP5 Plus','ilford-hp5-plus','ILFORD','HP5 PLUS','grotesk-blk','400','grotesk-blk','B&W','#F4F4F2','#151515','#151515','#151515',None),
 ('Ilford FP4 Plus','ilford-fp4-plus','ILFORD','FP4 PLUS','grotesk-blk','125','grotesk-blk','B&W','#F4F4F2','#151515','#2364AA','#2364AA',None),
 ('Ilford Delta 3200','ilford-delta-3200','ILFORD','DELTA','grotesk-blk','3200','grotesk-blk','B&W','#F4F4F2','#151515','#151515','#6A4A9C',None),
 ('Kentmere Pan 100','kentmere-pan-100','KENTMERE','PAN','grotesk-blk','100','thin-geo','B&W','#215DA8','#F2F2F0',None,None,None),
 ('CineStill 400D','cinestill-400d','CINESTILL','Dynamic','italic-wide','400D','hair-geo','C-41','#6A3FA0','#141414',None,None,None),
 ('CineStill 800T','cinestill-800t','CINESTILL','Tungsten','italic-wide','800T','hair-geo','C-41','#D2302C','#141414',None,None,None),
 ('CineStill 50D','cinestill-50d','CINESTILL','Daylight','italic-wide','50D','hair-geo','C-41','#1F6FD1','#141414',None,None,None),
 ('Lomography 400','lomography-400','LOMOGRAPHY','COLOR','grotesk-cap','400','grotesk-blk','C-41','#1F78B4','#F2C230',None,None,None),
]

def ink(hexc):
    c = int(hexc[1:], 16); r, g, b = c >> 16, c >> 8 & 255, c & 255
    return '#161616' if (r*299 + g*587 + b*114)/1000 > 150 else '#FFFFFF'

def darker(hexc, k):
    c = int(hexc[1:], 16); r, g, b = c >> 16, c >> 8 & 255, c & 255
    return '#%02X%02X%02X' % tuple(int(v*k) for v in (r, g, b))

def fit(text, style, box, maxh, ref=None):
    """Largest size whose ink fits box=(x0,y0,x1,y1) and whose height (of ref, default text) is <= maxh.
    Returns (size, x, baseline) with the ink's left edge on x0 and its bottom on y1."""
    f, ax, tr, sk, st = T[style] if isinstance(style, str) else style
    bx0, by0, bx1, by1 = ink_box(text, f, 100, ax, tr*100)
    rx0, ry0, rx1, ry1 = ink_box(ref or text, f, 100, ax, tr*100)
    k = min((box[2]-box[0]) / (bx1-bx0 + abs(sk)*(ry1-ry0) + 2*st*100), maxh / (ry1-ry0))
    size = 100*k
    return size, box[0] - bx0*k + st*size, box[3] - ry1*k - st*size

def text_path(text, style, size, x, y):
    f, ax, tr, sk, st = T[style]
    return path(text, f, size, x, y, ax, tr*size, sk), st*size

def svg(fid, brand, line, lstyle, iso, istyle, proc, bg, band, isoc, lc, effect):
    fg = ink(bg); bfg = ink(band); isoc = isoc or fg; lc = lc or fg
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">',
           f'<rect width="512" height="512" fill="{bg}"/>',
           f'<rect y="392" width="512" height="120" fill="{band}"/>']
    # series name, top left, full width: cap height <= LINE_CAP, cap top at y=56
    size, x, _ = fit(line, lstyle, (40, 0, 472, 0), LINE_CAP, ref='H')
    f, ax, tr, sk, st = T[lstyle]
    hx0, hy0, hx1, hy1 = ink_box('H', f, size, ax)
    base = 56 - hy0
    d, sw = text_path(line, lstyle, size, x, base)
    stroke = f' stroke="{lc}" stroke-width="{2*sw:.1f}" stroke-linejoin="round"' if sw else ''
    out.append(f'<path fill="{lc}"{stroke} d="{d}"/>')
    # ISO: ink height <= ISO_H, sits on y=362, right edge on x=472
    size, x, base = fit(iso, istyle, (40, 0, 472, 362), ISO_H)
    f, ax, tr, sk, st = T[istyle]
    x = 472 - ink_box(iso, f, size, ax, tr*size)[2] - st*size
    d, sw = text_path(iso, istyle, size, x, base)
    stroke = f' stroke="{isoc}" stroke-width="{2*sw:.1f}" stroke-linejoin="round"' if sw else ''
    if effect == 'extrude':
        # Tri-X: a short block shadow down and to the left, like the lettering on the box
        # (plain paths, no <use>: built-in SVGs stay inside the restricted subset, D-09)
        sh = darker(isoc, 0.45); n = 6; step = size*0.006
        shadow = ''.join(text_path(iso, istyle, size, x - i*step, base + i*step)[0] for i in range(n, 0, -1))
        out.append(f'<path fill="{sh}" d="{shadow}"/>')
        out.append(f'<path fill="{isoc}" d="{d}"/>')
    else:
        out.append(f'<path fill="{isoc}"{stroke} d="{d}"/>')
    # bottom band: brand only (the process is kept in the data but not drawn)
    bs = 40; btr = 0.16*bs; room = 432
    bw = ink_box(brand, UI_BRAND[0], bs, UI_BRAND[1], btr)
    if bw[2]-bw[0] > room:
        bs *= room/(bw[2]-bw[0]); btr = 0.16*bs
        bw = ink_box(brand, UI_BRAND[0], bs, UI_BRAND[1], btr)
    out.append(f'<path fill="{bfg}" d="{path(brand, UI_BRAND[0], bs, 40 - bw[0], 452 - (bw[1]+bw[3])/2, UI_BRAND[1], btr)}"/>')
    out.append('</svg>')
    return '\n'.join(out)

meta = []
for name, fid, brand, line, ls, iso, isty, proc, bg, band, isoc, lc, eff in F:
    maker = fid.split('-')[0]            # kodak, fujifilm, ilford ...: one folder per film maker
    os.makedirs(f'{OUT}/{maker}', exist_ok=True)
    open(f'{OUT}/{maker}/{fid}.svg', 'w').write(svg(fid, brand, line, ls, iso, isty, proc, bg, band, isoc, lc, eff))
    meta.append({'name': name, 'id': fid, 'maker': maker, 'process': proc, 'icon': f'{maker}/{fid}.svg'})
json.dump(meta, open(f'{OUT}/films.json', 'w'), ensure_ascii=False, indent=1)
print(len(meta), 'icons')
