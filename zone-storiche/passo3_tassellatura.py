# -*- coding: utf-8 -*-
# Passo 3 (rivisto): TASSELLATURA COMPLETA del territorio della filiale.
# Ogni cella del riquadro (anche senza consegne storiche) viene attribuita alla
# zona assegnata piu' vicina (crescita per adiacenza, BFS multi-sorgente);
# contiguita' a 4 vicini forzata e verificata: OGNI GIRO = UN SOLO POLIGONO
# (eventuali buchi = zone racchiuse), nessuna intersezione tra giri.
import numpy as np
import json, colorsys
from collections import deque

BASE = r"C:\Users\Carlo\AppData\Local\Temp\claude\C--progetti-AI-TWEB\53fa87f8-62f2-4876-98a8-b6325d6172f6\scratchpad"
dati = json.load(open(BASE + r"\zone_grosseto_full.json", encoding="utf-8"))
g = dati["griglia"]
LAT0, LNG0, SL, SG = g["lat0"], g["lng0"], g["sl"], g["sg"]
K = dati["k"]

# riquadro completo (stesso filtro del passo 1)
NY = int((43.35 - LAT0) / SL) + 1
NX = int((11.65 - LNG0) / SG) + 1
Z = np.zeros((NY, NX), dtype=np.int16)          # 0 = non attribuita
for c in dati["celleFull"]:
    Z[c["cy"], c["cx"]] = c["zona"]
print(f"griglia {NY}x{NX} = {NY*NX} celle | seminate: {(Z>0).sum()}")

# --- crescita per adiacenza (4 vicini): ogni cella vuota va alla zona piu' vicina ---
coda = deque((cy, cx) for cy in range(NY) for cx in range(NX) if Z[cy, cx] > 0)
while coda:
    cy, cx = coda.popleft()
    z = Z[cy, cx]
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        ny, nx = cy + dy, cx + dx
        if 0 <= ny < NY and 0 <= nx < NX and Z[ny, nx] == 0:
            Z[ny, nx] = z
            coda.append((ny, nx))
print("copertura completa:", (Z == 0).sum() == 0)

# --- contiguita' a 4 vicini: ogni zona deve essere un solo blocco ---
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

for giro_ in range(60):
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
                      if 0 <= cy + dy < NY and 0 <= cx + dx < NX and Z[cy + dy, cx + dx] != z]
                if vz:
                    Z[cy, cx] = np.bincount(vz).argmax()
    if not rotte:
        break
for z in range(1, K + 1):
    n = len(componenti(z))
    assert n == 1, f"zona {z}: {n} componenti"
print("verifica: ogni giro e' un unico blocco")

# --- anelli di contorno (bordi diretti, interno a sinistra) ---
def anelli_zona(z):
    S = {(cy, cx) for cy, cx in zip(*np.where(Z == z))}
    edges = {}
    for (cy, cx) in S:
        if (cy - 1, cx) not in S: edges.setdefault((cx, cy), []).append((cx + 1, cy))
        if (cy, cx + 1) not in S: edges.setdefault((cx + 1, cy), []).append((cx + 1, cy + 1))
        if (cy + 1, cx) not in S: edges.setdefault((cx + 1, cy + 1), []).append((cx, cy + 1))
        if (cy, cx - 1) not in S: edges.setdefault((cx, cy + 1), []).append((cx, cy))
    usati = set()
    anelli = []
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
                def svolta(e):
                    d2 = (e[0] - nxt[0], e[1] - nxt[1])
                    return -np.arctan2(dirv[0] * d2[1] - dirv[1] * d2[0], dirv[0] * d2[0] + dirv[1] * d2[1])
                e = min(cand, key=svolta)
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

v2lat = lambda v: LAT0 + v[1] * SL
v2lng = lambda v: LNG0 + v[0] * SG

wkt_zone, poligoni = {}, {}
for z in range(1, K + 1):
    anelli = anelli_zona(z)
    esterni = [a for a in anelli if area_firmata(a) > 0]
    buchi = [a for a in anelli if area_firmata(a) < 0]
    assert len(esterni) == 1, f"zona {z}: {len(esterni)} anelli esterni"
    rings = [esterni[0]] + buchi
    testi = []
    for r in rings:
        pts = r + [r[0]]
        testi.append("(" + ", ".join(f"{v2lng(v):.6f} {v2lat(v):.6f}" for v in pts) + ")")
    wkt_zone[z] = "POLYGON (" + ", ".join(testi) + ")"
    poligoni[z] = [[[v2lat(v), v2lng(v)] for v in r] for r in rings]
    print(f"zona {z:2}: 1 poligono, {len(buchi)} buchi (zone interne), {len(esterni[0])} vertici, wkt {len(wkt_zone[z])} car.")

dati["wkt"] = {str(z): w for z, w in wkt_zone.items()}
dati["poligoni"] = {str(z): p for z, p in poligoni.items()}
with open(BASE + r"\zone_grosseto_full.json", "w", encoding="utf-8") as f:
    json.dump(dati, f, ensure_ascii=False)

def hsl2hex(z):
    h = ((z - 1) * 137.508 % 360) / 360
    r, gg, b = colorsys.hls_to_rgb(h, 0.45, 0.68)
    return "#{:02X}{:02X}{:02X}".format(int(r * 255), int(gg * 255), int(b * 255))

righe = ["""-- Zone storiche GROSSETO_2: TASSELLATURA COMPLETA del territorio in 16 giri,
-- ognuno UN SOLO poligono (buchi = zone racchiuse), senza intersezioni ne' aree
-- scoperte: ogni punto del riquadro operativo appartiene a un giro preciso.
-- Generato dalla pipeline zone-storiche; NON eseguire senza conferma.
CREATE OR ALTER PROCEDURE dbo.AI_GEO_ZonaStorica_Save
    @IdFiliale int, @Giro varchar(200), @Colore varchar(20), @WKT nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @shape geometry = geometry::STGeomFromText(@WKT, 4326).MakeValid();
    IF EXISTS (SELECT 1 FROM GEO_GIRI WHERE IdFiliale = @IdFiliale AND Giro = @Giro AND DataFine IS NULL)
        UPDATE GEO_GIRI SET SHAPE = @shape, Colore = @Colore, DataModifica = GETDATE()
        WHERE IdFiliale = @IdFiliale AND Giro = @Giro AND DataFine IS NULL;
    ELSE
        INSERT INTO GEO_GIRI (IdFiliale, Giro, Colore, SHAPE, DataModifica)
        VALUES (@IdFiliale, @Giro, @Colore, @shape, GETDATE());
    SELECT IdGiro FROM GEO_GIRI WHERE IdFiliale = @IdFiliale AND Giro = @Giro AND DataFine IS NULL;
END
GO
GRANT EXECUTE ON dbo.AI_GEO_ZonaStorica_Save TO claude;
GO"""]
for z in range(1, K + 1):
    w = wkt_zone[z].replace("'", "''")
    righe.append(f"EXEC dbo.AI_GEO_ZonaStorica_Save @IdFiliale = 31, @Giro = 'ZONA STORICA {z:02}',"
                 f" @Colore = '{hsl2hex(z)}', @WKT = '{w}';")
open(BASE + r"\zone_grosseto_giri.sql", "w", encoding="utf-8").write("\n".join(righe))
print("scritti zone_grosseto_full.json (poligoni) e zone_grosseto_giri.sql")
