# -*- coding: utf-8 -*-
# Passo 4a: frame per le slide — progressione punti (1g, 2g, 1 settimana, 1 mese,
# periodo intero) -> zone passo 1 -> aree finali passo 2+3 con contorni.
# Basemap: tile OpenStreetMap (z11) con cache locale.
import pandas as pd
import numpy as np
import json, math, os, re, colorsys, time
import requests
from PIL import Image, ImageDraw

BASE = r"C:\Users\Carlo\AppData\Local\Temp\claude\C--progetti-AI-TWEB\53fa87f8-62f2-4876-98a8-b6325d6172f6\scratchpad"
TILES = BASE + r"\tiles_li"
FRAMES = BASE + r"\frames_li"
os.makedirs(TILES, exist_ok=True)
os.makedirs(FRAMES, exist_ok=True)

Z = 13
LAT_MIN, LAT_MAX, LNG_MIN, LNG_MAX = 43.46, 43.63, 10.27, 10.44

def merc(lat, lng):
    n = 2 ** Z
    x = (lng + 180) / 360 * n
    la = math.radians(lat)
    y = (1 - math.log(math.tan(la) + 1 / math.cos(la)) / math.pi) / 2 * n
    return x, y

x0, y0 = merc(LAT_MAX, LNG_MIN)     # angolo alto-sinistra
x1, y1 = merc(LAT_MIN, LNG_MAX)
tx0, ty0, tx1, ty1 = int(x0), int(y0), int(x1), int(y1)

sess = requests.Session()
sess.headers["User-Agent"] = "SpeedyWeb-analisi/1.0 (speedyworld.it)"
mappa = Image.new("RGB", ((tx1 - tx0 + 1) * 256, (ty1 - ty0 + 1) * 256), "#ddd")
for tx in range(tx0, tx1 + 1):
    for ty in range(ty0, ty1 + 1):
        p = f"{TILES}\\{Z}_{tx}_{ty}.png"
        if not os.path.exists(p):
            r = sess.get(f"https://tile.openstreetmap.org/{Z}/{tx}/{ty}.png", timeout=30)
            open(p, "wb").write(r.content)
            time.sleep(0.15)
        mappa.paste(Image.open(p).convert("RGB"), ((tx - tx0) * 256, (ty - ty0) * 256))

# ritaglio esatto del bbox
px0, py0 = (x0 - tx0) * 256, (y0 - ty0) * 256
px1, py1 = (x1 - tx0) * 256, (y1 - ty0) * 256
mappa = mappa.crop((int(px0), int(py0), int(px1), int(py1)))
W, H = mappa.size
print("basemap:", W, "x", H)
# schiarita per far risaltare i dati
mappa = Image.blend(mappa, Image.new("RGB", mappa.size, "white"), 0.35)

def pix(lat, lng):
    x, y = merc(lat, lng)
    return ((x - x0) / (x1 - x0) * W, (y - y0) / (y1 - y0) * H)

def col_zona(z, a=255):
    h = ((z - 1) * 137.508 % 360) / 360
    r, g, b = colorsys.hls_to_rgb(h, 0.45, 0.68)
    return (int(r * 255), int(g * 255), int(b * 255), a)

# --- dati ---
df = pd.read_csv(BASE + r"\livorno.csv")
df = df[(df.lat > 43.40) & (df.lat < 43.65) & (df.lng > 10.25) & (df.lng < 10.45)].copy()
df["drv"] = df.postino.str.replace(r"_\d+$", "", regex=True).str.lower()
df["_cy"] = ((df.lat - 43.40) / 0.002).astype(int)
df["_cx"] = ((df.lng - 10.25) / 0.00275).astype(int)
prima = len(df)
df = df[~((df._cy == 78) & (df._cx == 32))]
print("esclusi dalla grafica (cella-discarica):", prima - len(df))
df = df.sort_values("giorno")
giorni = sorted(df.giorno.unique())
dati = json.load(open(BASE + r"\zone_livorno.json", encoding="utf-8"))
g = dati["griglia"]

# colori per driver (i principali, il resto grigio)
principali = df.groupby("drv").size().sort_values(ascending=False).head(8).index.tolist()
col_drv = {d: col_zona(i + 1) for i, d in enumerate(principali)}

def frame_punti(nome, n_giorni, titolo):
    img = mappa.copy()
    dr = ImageDraw.Draw(img)
    sotto = df[df.giorno.isin(giorni[:n_giorni])] if n_giorni else df
    for r in sotto.itertuples():
        x, y = pix(r.lat, r.lng)
        c = col_drv.get(r.drv, (110, 110, 110, 255))
        dr.ellipse([x - 2.2, y - 2.2, x + 2.2, y + 2.2], fill=c[:3])
    img.save(f"{FRAMES}\\{nome}.png")
    print(nome, len(sotto), "punti")

frame_punti("f1_giorno1", 1, "")
frame_punti("f2_giorni2", 2, "")
frame_punti("f3_settimana", 7, "")
frame_punti("f4_mese", 26, "")          # ~1 mese lavorativo
frame_punti("f5_periodo", None, "")

# --- frame zone passo 1 (celle core) ---
def frame_celle(nome, celle, con_bordi):
    img = mappa.copy().convert("RGBA")
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    dr = ImageDraw.Draw(ov)
    for c in celle:
        la0 = g["lat0"] + c["cy"] * g["sl"]
        lo0 = g["lng0"] + c["cx"] * g["sg"]
        xa, ya = pix(la0 + g["sl"], lo0)
        xb, yb = pix(la0, lo0 + g["sg"])
        a = 90 if c.get("attribuita") else 150
        dr.rectangle([xa, ya, xb, yb], fill=col_zona(c["zona"], a))
    img = Image.alpha_composite(img, ov)
    if con_bordi:
        dr2 = ImageDraw.Draw(img)
        for z, wkt in dati["wkt"].items():
            for ring in re.findall(r"\(([-0-9. ,]+)\)", wkt):
                pts = []
                for coppia in ring.split(","):
                    lng_, lat_ = map(float, coppia.split())
                    pts.append(pix(lat_, lng_))
                dr2.line(pts + [pts[0]], fill=col_zona(int(z))[:3], width=4)
    # etichette zona
    dr3 = ImageDraw.Draw(img)
    from PIL import ImageFont
    try:
        font = ImageFont.truetype(r"C:\Windows\Fonts\arialbd.ttf", 30)
    except Exception:
        font = ImageFont.load_default()
    for st in dati["zone"]:
        cz = [c for c in celle if c["zona"] == st["zona"] and not c.get("attribuita")]
        if not cz:
            continue
        sy = sum(g["lat0"] + (c["cy"] + .5) * g["sl"] for c in cz) / len(cz)
        sx = sum(g["lng0"] + (c["cx"] + .5) * g["sg"] for c in cz) / len(cz)
        x, y = pix(sy, sx)
        dr3.ellipse([x - 21, y - 21, x + 21, y + 21], fill="white", outline=col_zona(st["zona"])[:3], width=4)
        dr3.text((x, y - 2), str(st["zona"]), fill="#222", font=font, anchor="mm")
    img.convert("RGB").save(f"{FRAMES}\\{nome}.png")
    print(nome, "ok")

frame_celle("f6_zone_passo1", dati["celle"], False)

# f7: tassellatura completa (un poligono per giro) + celle storiche sopra
def frame_tassellatura(nome):
    img = mappa.copy().convert("RGBA")
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    for z, polys in dati["poligoniProv"].items():
        for poly in polys:
            msk = Image.new("L", img.size, 0)
            dm = ImageDraw.Draw(msk)
            dm.polygon([pix(lat_, lng_) for lat_, lng_ in poly[0]], fill=255)
            for buco in poly[1:]:
                dm.polygon([pix(lat_, lng_) for lat_, lng_ in buco], fill=0)
            tinta = Image.new("RGBA", img.size, col_zona(int(z), 80))
            ov.paste(tinta, (0, 0), msk)
    dr = ImageDraw.Draw(ov)
    for c in dati["celle"]:
        la0 = g["lat0"] + c["cy"] * g["sl"]
        lo0 = g["lng0"] + c["cx"] * g["sg"]
        xa, ya = pix(la0 + g["sl"], lo0)
        xb, yb = pix(la0, lo0 + g["sg"])
        dr.rectangle([xa, ya, xb, yb], fill=col_zona(c["zona"], 150))
    img = Image.alpha_composite(img, ov)
    dr2 = ImageDraw.Draw(img)
    for z, polys in dati["poligoniProv"].items():
        for poly in polys:
            for ring in poly:
                pts = [pix(lat_, lng_) for lat_, lng_ in ring]
                dr2.line(pts + [pts[0]], fill=col_zona(int(z))[:3], width=4)
    dr3 = ImageDraw.Draw(img)
    from PIL import ImageFont
    try:
        font = ImageFont.truetype(r"C:\Windows\Fonts\arialbd.ttf", 30)
    except Exception:
        font = ImageFont.load_default()
    for st in dati["zone"]:
        cz = [c for c in dati["celle"] if c["zona"] == st["zona"]]
        if cz:
            sy = sum(g["lat0"] + (c["cy"] + .5) * g["sl"] for c in cz) / len(cz)
            sx = sum(g["lng0"] + (c["cx"] + .5) * g["sg"] for c in cz) / len(cz)
        else:
            # zona senza storia (isole): etichetta al centro del poligono
            ring = dati["poligoniProv"][str(st["zona"])][0][0]
            sy = sum(p[0] for p in ring) / len(ring)
            sx = sum(p[1] for p in ring) / len(ring)
        x, y = pix(sy, sx)
        dr3.ellipse([x - 21, y - 21, x + 21, y + 21], fill="white", outline=col_zona(st["zona"])[:3], width=4)
        dr3.text((x, y - 2), str(st["zona"]), fill="#222", font=font, anchor="mm")
    img.convert("RGB").save(f"{FRAMES}\\{nome}.png")
    print(nome, "ok")

frame_tassellatura("f7_aree_finali")

# legenda driver per le slide dei punti
leg = Image.new("RGB", (460, 40 + 34 * len(principali)), "white")
dl = ImageDraw.Draw(leg)
from PIL import ImageFont
try:
    f1 = ImageFont.truetype(r"C:\Windows\Fonts\arialbd.ttf", 22)
    f2 = ImageFont.truetype(r"C:\Windows\Fonts\arial.ttf", 22)
except Exception:
    f1 = f2 = ImageFont.load_default()
dl.text((16, 10), "Driver principali", fill="#222", font=f1)
for i, d in enumerate(principali):
    y = 46 + i * 34
    dl.ellipse([18, y, 40, y + 22], fill=col_drv[d][:3])
    dl.text((52, y + 1), d, fill="#333", font=f2)
leg.save(f"{FRAMES}\\legenda_driver.png")
print("legenda ok")
