# -*- coding: utf-8 -*-
# Livorno, passi 2+3: attribuzione delle celle scarse, tassellatura completa,
# preparazione del ritaglio sul COMUNE di Livorno (il 99,95% delle consegne
# LIVORNO_2 e' nel comune). Isole: Gorgona (parte del comune) e Capraia
# (comune a se') diventano giri dedicati.
import pandas as pd
import numpy as np
import json
from collections import deque

BASE = r"C:\Users\Carlo\AppData\Local\Temp\claude\C--progetti-AI-TWEB\53fa87f8-62f2-4876-98a8-b6325d6172f6\scratchpad"
dati = json.load(open(BASE + r"\zone_livorno.json", encoding="utf-8"))
g = dati["griglia"]
LAT0, LNG0, SL, SG = g["lat0"], g["lng0"], g["sl"], g["sg"]
K = dati["k"]

def parse_wkt(w):
    w = w.strip()
    base_prof = 1 if w.upper().startswith("MULTIPOLYGON") else 0
    corpo = w[w.index("("):]
    poligoni, prof, anelli, ring_start = [], 0, None, None
    for i, ch in enumerate(corpo):
        if ch == "(":
            prof += 1
            if prof == base_prof + 1: anelli = []
            if prof == base_prof + 2: ring_start = i + 1
        elif ch == ")":
            if prof == base_prof + 2:
                ring = []
                for c in corpo[ring_start:i].split(","):
                    p = c.split()
                    ring.append((float(p[0]), float(p[1])))
                anelli.append(ring)
            if prof == base_prof + 1 and anelli:
                poligoni.append(anelli); anelli = None
            prof -= 1
    return poligoni

def area_poly(ring):
    s = 0
    for i in range(len(ring)):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % len(ring)]
        s += x1 * y2 - x2 * y1
    return abs(s / 2) * 1e6

comune = parse_wkt(open(BASE + r"\comune_Livorno.wkt", encoding="utf-8-sig").read().split("\n-----")[0])
comune.sort(key=lambda p: -area_poly(p[0]))
print("comune di Livorno: parti", [round(area_poly(p[0]), 1) for p in comune])

# riquadro della griglia dall'envelope della parte principale (+ margine)
xs = [p[0] for p in comune[0][0]]
ys = [p[1] for p in comune[0][0]]
LATMIN, LATMAX = min(ys) - 0.01, max(ys) + 0.01
LNGMIN, LNGMAX = min(xs) - 0.01, max(xs) + 0.01
print(f"riquadro comune: lat {LATMIN:.3f}-{LATMAX:.3f} lng {LNGMIN:.3f}-{LNGMAX:.3f}")

# --- passo 2: celle con punti non assegnate -> zona core piu' vicina ---
df = pd.read_csv(BASE + r"\livorno.csv")
df = df[(df.lat > 43.40) & (df.lat < 43.65) & (df.lng > 10.25) & (df.lng < 10.45)].copy()
df["cy"] = ((df.lat - LAT0) / SL).astype(int)
df["cx"] = ((df.lng - LNG0) / SG).astype(int)
tutte = df.groupby(["cy", "cx"]).size()
core = {(c["cy"], c["cx"]): c["zona"] for c in dati["celle"]}
core_yx = np.array(list(core.keys()), dtype=float)
core_z = np.array(list(core.values()))
zona_cella = dict(core)
n_attr = 0
for (cy, cx), n in tutte.items():
    if (cy, cx) in zona_cella:
        continue
    d2 = (core_yx[:, 0] - cy) ** 2 + ((core_yx[:, 1] - cx) * 0.72) ** 2
    zona_cella[(cy, cx)] = int(core_z[np.argmin(d2)])
    n_attr += 1
print(f"celle attribuite (scarse o discarica): {n_attr}")
dati["celleFull"] = [{"cy": cy, "cx": cx, "zona": zz, "attribuita": (cy, cx) not in core}
                     for (cy, cx), zz in sorted(zona_cella.items())]

# --- passo 3a: tassellatura completa del riquadro comunale ---
NY = int((43.65 - LAT0) / SL) + 1
NX = int((10.45 - LNG0) / SG) + 1
CY0, CX0 = 0, 0
Z = np.zeros((NY, NX), dtype=np.int16)
for (cy, cx), zz in zona_cella.items():
    if 0 <= cy < NY and 0 <= cx < NX:
        Z[cy, cx] = zz
coda = deque((cy, cx) for cy in range(NY) for cx in range(NX) if Z[cy, cx] > 0)
while coda:
    cy, cx = coda.popleft()
    z = Z[cy, cx]
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        ny, nx = cy + dy, cx + dx
        if 0 <= ny < NY and 0 <= nx < NX and Z[ny, nx] == 0:
            Z[ny, nx] = z
            coda.append((ny, nx))
print("copertura riquadro:", (Z[max(CY0,0):, max(CX0,0):] == 0).sum() == 0)

def componenti(z):
    m = Z == z
    visite = np.zeros_like(m)
    comp = []
    for sy, sx in zip(*np.where(m)):
        if visite[sy, sx]:
            continue
        cc = []
        stack = [(sy, sx)]
        visite[sy, sx] = True
        while stack:
            cy, cx = stack.pop()
            cc.append((cy, cx))
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                ny, nx = cy + dy, cx + dx
                if 0 <= ny < NY and 0 <= nx < NX and m[ny, nx] and not visite[ny, nx]:
                    visite[ny, nx] = True
                    stack.append((ny, nx))
        comp.append(cc)
    return comp

for _ in range(60):
    rotte = False
    for z in range(1, K + 1):
        comp = componenti(z)
        if len(comp) <= 1:
            continue
        rotte = True
        comp.sort(key=len, reverse=True)
        for cc in comp[1:]:
            for cy, cx in cc:
                vz = [Z[cy + dy, cx + dx] for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1))
                      if 0 <= cy + dy < NY and 0 <= cx + dx < NX and Z[cy + dy, cx + dx] not in (z, 0)]
                if vz:
                    Z[cy, cx] = np.bincount(vz).argmax()
    if not rotte:
        break
for z in range(1, K + 1):
    assert len(componenti(z)) == 1, f"zona {z} spezzata"
print("ogni zona e' un blocco unico")

# --- contorni di griglia ---
def anelli_zona(z):
    S = {(cy, cx) for cy, cx in zip(*np.where(Z == z))}
    edges = {}
    for (cy, cx) in S:
        if (cy - 1, cx) not in S: edges.setdefault((cx, cy), []).append((cx + 1, cy))
        if (cy, cx + 1) not in S: edges.setdefault((cx + 1, cy), []).append((cx + 1, cy + 1))
        if (cy + 1, cx) not in S: edges.setdefault((cx + 1, cy + 1), []).append((cx, cy + 1))
        if (cy, cx - 1) not in S: edges.setdefault((cx, cy + 1), []).append((cx, cy))
    usati, anelli = set(), []
    for start in list(edges):
        for fine0 in edges[start]:
            if (start, fine0) in usati:
                continue
            anello = [start]
            cur, nxt = start, fine0
            usati.add((cur, nxt))
            while nxt != start:
                anello.append(nxt)
                dirv = (nxt[0] - cur[0], nxt[1] - cur[1])
                cand = [e for e in edges.get(nxt, []) if (nxt, e) not in usati]
                if not cand:
                    break
                e = min(cand, key=lambda e: -np.arctan2(dirv[0] * (e[1] - nxt[1]) - dirv[1] * (e[0] - nxt[0]),
                                                        dirv[0] * (e[0] - nxt[0]) + dirv[1] * (e[1] - nxt[1])))
                usati.add((nxt, e))
                cur, nxt = nxt, e
            if nxt == start and len(anello) >= 4:
                puliti = []
                m = len(anello)
                for i in range(m):
                    a, b, c = anello[i - 1], anello[i], anello[(i + 1) % m]
                    if (b[0] - a[0]) * (c[1] - b[1]) != (b[1] - a[1]) * (c[0] - b[0]):
                        puliti.append(b)
                anelli.append(puliti)
    return anelli

def area_firmata(an):
    s = 0
    for i in range(len(an)):
        x1, y1 = an[i]
        x2, y2 = an[(i + 1) % len(an)]
        s += x1 * y2 - x2 * y1
    return s / 2

v2lng = lambda v: LNG0 + v[0] * SG
v2lat = lambda v: LAT0 + v[1] * SL

righe = ["SET NOCOUNT ON;",
         "DECLARE @com geometry = (SELECT SHAPE.MakeValid() FROM GEO_COMUNE WHERE DENOMINAZIONE = 'Livorno');",
         "DECLARE @terra geometry; DECLARE @i int = 1, @best float = 0; "
         "WHILE @i <= @com.STNumGeometries() BEGIN IF @com.STGeometryN(@i).STArea() > @best "
         "BEGIN SET @best = @com.STGeometryN(@i).STArea(); SET @terra = @com.STGeometryN(@i) END; SET @i += 1 END;"]
for z in range(1, K + 1):
    anelli = anelli_zona(z)
    esterni = [a for a in anelli if area_firmata(a) > 0]
    buchi = [a for a in anelli if area_firmata(a) < 0]
    testi = []
    for r in esterni + buchi:
        pts = r + [r[0]]
        testi.append("(" + ", ".join(f"{v2lng(v):.6f} {v2lat(v):.6f}" for v in pts) + ")")
    w = ("POLYGON (" + ", ".join(testi) + ")").replace("'", "''")
    righe.append(f"DECLARE @z{z} geometry = geometry::STGeomFromText('{w}', 4326).MakeValid().STIntersection(@terra);")
    righe.append(f"SELECT {z} AS zona, @z{z}.STNumGeometries() AS parti, @z{z}.STAsText() AS wkt;")
open(BASE + r"\ritaglio_li.sql", "w", encoding="utf-8").write("\n".join(righe))
json.dump(dati, open(BASE + r"\zone_livorno.json", "w", encoding="utf-8"), ensure_ascii=False)
print("scritta ritaglio_li.sql")
