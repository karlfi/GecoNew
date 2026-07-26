# -*- coding: utf-8 -*-
# Passo 3 (rifinito): niente mare — giri ritagliati sulla PROVINCIA di Grosseto;
# le isole diventano giri dedicati (uno per isola). Fase A: prepara i poligoni
# di griglia senza le celle delle isole e lo script SQL di ritaglio (sola lettura).
import numpy as np
import json, re
from collections import deque

BASE = r"C:\Users\Carlo\AppData\Local\Temp\claude\C--progetti-AI-TWEB\53fa87f8-62f2-4876-98a8-b6325d6172f6\scratchpad"
dati = json.load(open(BASE + r"\zone_grosseto_full.json", encoding="utf-8"))
g = dati["griglia"]
LAT0, LNG0, SL, SG = g["lat0"], g["lng0"], g["sl"], g["sg"]
K = dati["k"]

# --- parser WKT minimale (POLYGON/MULTIPOLYGON -> lista di poligoni [anelli [xy]]) ---
def parse_wkt(w):
    w = w.strip()
    tipo = "MULTI" if w.upper().startswith("MULTIPOLYGON") else "POLY"
    corpo = w[w.index("("):]
    # tokenizza per profondita'
    poligoni = []
    prof, inizio = 0, None
    base_prof = 1 if tipo == "MULTI" else 0
    anelli_correnti = None
    i = 0
    ring_start = None
    for i, ch in enumerate(corpo):
        if ch == "(":
            prof += 1
            if prof == base_prof + 1:
                anelli_correnti = []
            if prof == base_prof + 2:
                ring_start = i + 1
        elif ch == ")":
            if prof == base_prof + 2:
                coppie = corpo[ring_start:i].split(",")
                ring = []
                for c in coppie:
                    p = c.split()
                    ring.append((float(p[0]), float(p[1])))
                anelli_correnti.append(ring)
            if prof == base_prof + 1:
                if anelli_correnti:
                    poligoni.append(anelli_correnti)
                anelli_correnti = None
            prof -= 1
    return poligoni

def dentro(px, py, ring):
    d = False
    m = len(ring)
    for i in range(m):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % m]
        if (y1 > py) != (y2 > py) and px < (x2 - x1) * (py - y1) / (y2 - y1) + x1:
            d = not d
    return d

giglio = parse_wkt(open(BASE + r"\giglio.wkt", encoding="utf-8").read().split("\n-----")[0])
giglio_ring = giglio[0][0]

# --- ricostruisci la tassellatura completa (come passo3b) ---
NY = int((43.35 - LAT0) / SL) + 1
NX = int((11.90 - LNG0) / SG) + 1
Z = np.zeros((NY, NX), dtype=np.int16)
for c in dati["celleFull"]:
    Z[c["cy"], c["cx"]] = c["zona"]
coda = deque((cy, cx) for cy in range(NY) for cx in range(NX) if Z[cy, cx] > 0)
while coda:
    cy, cx = coda.popleft()
    z = Z[cy, cx]
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        ny, nx = cy + dy, cx + dx
        if 0 <= ny < NY and 0 <= nx < NX and Z[ny, nx] == 0:
            Z[ny, nx] = z
            coda.append((ny, nx))

# --- isole: celle del Giglio fuori dai giri di terraferma (giro dedicato) ---
GIGLIO = 90
n_giglio_storiche = 0
for cy in range(NY):
    for cx in range(NX):
        clat = LAT0 + (cy + .5) * SL
        clng = LNG0 + (cx + .5) * SG
        if 42.30 < clat < 42.42 and 10.85 < clng < 10.96 and dentro(clng, clat, giglio_ring):
            Z[cy, cx] = GIGLIO
storiche_giglio = [c for c in dati["celle"] if dentro(LNG0 + (c["cx"] + .5) * SG, LAT0 + (c["cy"] + .5) * SL, giglio_ring)]
print("celle storiche sul Giglio:", len(storiche_giglio),
      "| zona di provenienza:", sorted({c["zona"] for c in storiche_giglio}))

# Giannutri: consegne storiche nell'area?
giann = [c for c in dati["celleFull"] if 42.20 <= LAT0 + c["cy"] * SL <= 42.30 and 11.05 <= LNG0 + c["cx"] * SG <= 11.15]
print("celle storiche zona Giannutri:", len(giann))

# --- contorni di griglia per i giri 1..16 (il ritaglio costa lo fa SQL) ---
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

# togliere il Giglio non deve spezzare i giri di terraferma
for giro_ in range(20):
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
                      if 0 <= cy + dy < NY and 0 <= cx + dx < NX and Z[cy + dy, cx + dx] not in (z, GIGLIO)]
                if vz:
                    Z[cy, cx] = np.bincount(vz).argmax()
    if not rotte:
        break
for z in range(1, K + 1):
    assert len(componenti(z)) == 1, f"zona {z} spezzata"
print("terraferma: ogni giro resta un blocco unico")

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

wkt_grid = {}
for z in range(1, K + 1):
    anelli = anelli_zona(z)
    esterni = [a for a in anelli if area_firmata(a) > 0]
    buchi = [a for a in anelli if area_firmata(a) < 0]
    rings = esterni + buchi
    testi = []
    for r in rings:
        pts = r + [r[0]]
        testi.append("(" + ", ".join(f"{v2lng(v):.6f} {v2lat(v):.6f}" for v in pts) + ")")
    wkt_grid[z] = "POLYGON (" + ", ".join(testi) + ")"

# --- query di ritaglio (SOLA LETTURA): interseca ogni giro con la terraferma ---
righe = ["SET NOCOUNT ON;",
         "DECLARE @prov geometry = (SELECT geometry::UnionAggregate(SHAPE.MakeValid()) FROM GEO_COMUNE WHERE SIGLAPROV='GR');",
         "DECLARE @terra geometry; DECLARE @i int = 1, @best float = 0; WHILE @i <= @prov.STNumGeometries() BEGIN IF @prov.STGeometryN(@i).STArea() > @best BEGIN SET @best = @prov.STGeometryN(@i).STArea(); SET @terra = @prov.STGeometryN(@i) END; SET @i += 1 END;"]
for z in range(1, K + 1):
    w = wkt_grid[z].replace("'", "''")
    righe.append(f"DECLARE @z{z} geometry = geometry::STGeomFromText('{w}', 4326).MakeValid().STIntersection(@terra);")
    righe.append(f"SELECT {z} AS zona, @z{z}.STNumGeometries() AS parti, @z{z}.STAsText() AS wkt;")
open(BASE + r"\ritaglio.sql", "w", encoding="utf-8").write("\n".join(righe))
print("scritta ritaglio.sql")
