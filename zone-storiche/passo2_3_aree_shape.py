# -*- coding: utf-8 -*-
# Passo 2: attribuisce le aree non assegnate (celle a bassa densita' e buchi
#          interni) alla zona piu' vicina.
# Passo 3: contorni delle zone (anelli rettilinei dell'unione celle) -> WKT
#          MULTIPOLYGON + script SQL pronto per GEO_GIRI (geometry, SRID 4326).
import pandas as pd
import numpy as np
import json

BASE = r"C:\Users\Carlo\AppData\Local\Temp\claude\C--progetti-AI-TWEB\53fa87f8-62f2-4876-98a8-b6325d6172f6\scratchpad"
dati = json.load(open(BASE + r"\zone_grosseto.json", encoding="utf-8"))
g = dati["griglia"]
LAT0, LNG0, SL, SG = g["lat0"], g["lng0"], g["sl"], g["sg"]

df = pd.read_csv(BASE + r"\grosseto.csv")
df = df[(df.lat > 42.2) & (df.lat < 43.35) & (df.lng > 10.4) & (df.lng < 11.65)].copy()
df["cy"] = ((df.lat - LAT0) / SL).astype(int)
df["cx"] = ((df.lng - LNG0) / SG).astype(int)
tutte = df.groupby(["cy", "cx"]).size()          # tutte le celle con almeno 1 punto

core = {(c["cy"], c["cx"]): c["zona"] for c in dati["celle"]}
print(f"celle core: {len(core)} | celle totali con punti: {len(tutte)}")

# --- passo 2a: celle con punti ma senza zona -> zona della cella core piu' vicina ---
core_k = list(core.keys())
core_yx = np.array(core_k, dtype=float)
core_z = np.array([core[k] for k in core_k])
attrib = {}
for (cy, cx), n in tutte.items():
    if (cy, cx) in core:
        continue
    d2 = (core_yx[:, 0] - cy) ** 2 + ((core_yx[:, 1] - cx) * (SG * 81.7) / (SL * 111.32)) ** 2
    attrib[(cy, cx)] = int(core_z[np.argmin(d2)])
print(f"celle attribuite alla zona piu' vicina: {len(attrib)}")

zona_cella = dict(core)
zona_cella.update(attrib)

# --- passo 2b: chiusura dei buchi interni (celle vuote circondate da assegnate) ---
riempite = 0
for _ in range(2):
    nuovi = {}
    occupate = set(zona_cella.keys())
    candidate = set()
    for (cy, cx) in occupate:
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                v = (cy + dy, cx + dx)
                if v not in occupate:
                    candidate.add(v)
    for v in candidate:
        vic = [zona_cella[(v[0] + dy, v[1] + dx)]
               for dy in (-1, 0, 1) for dx in (-1, 0, 1)
               if (dy, dx) != (0, 0) and (v[0] + dy, v[1] + dx) in occupate]
        if len(vic) >= 6:                        # buco interno vero
            nuovi[v] = int(np.bincount(vic).argmax())
    zona_cella.update(nuovi)
    riempite += len(nuovi)
    if not nuovi:
        break
print(f"buchi interni riempiti: {riempite} | celle totali finali: {len(zona_cella)}")

# --- passo 3: anelli di contorno per zona (bordi diretti, interno a sinistra) ---
def anelli_zona(cs):
    S = set(cs)
    edges = {}                                    # (vertice partenza) -> [(vertice arrivo)]
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
                # ai vertici doppi scegli la svolta piu' a sinistra (anelli semplici)
                def svolta(e):
                    d2 = (e[0] - nxt[0], e[1] - nxt[1])
                    cross = dirv[0] * d2[1] - dirv[1] * d2[0]
                    dot = dirv[0] * d2[0] + dirv[1] * d2[1]
                    return -np.arctan2(cross, dot)
                e = min(cand, key=svolta)
                usati.add((nxt, e))
                cur, nxt = nxt, e
            if nxt == start and len(anello) >= 4:
                # togli i punti collineari
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

def dentro(px, py, an):
    dentro_ = False
    m = len(an)
    for i in range(m):
        x1, y1 = an[i]
        x2, y2 = an[(i + 1) % m]
        if (y1 > py) != (y2 > py) and px < (x2 - x1) * (py - y1) / (y2 - y1) + x1:
            dentro_ = not dentro_
    return dentro_

def v2ll(v):
    return (LNG0 + v[0] * SG, LAT0 + v[1] * SL)   # WKT: X=lng Y=lat

K = dati["k"]
wkt_zone = {}
for z in range(1, K + 1):
    cs = [c for c, zz in zona_cella.items() if zz == z]
    anelli = anelli_zona(cs)
    esterni = [a for a in anelli if area_firmata(a) > 0]
    buchi = [a for a in anelli if area_firmata(a) < 0]
    parti = []
    for est in esterni:
        miei = [b for b in buchi if dentro(b[0][0] + .01, b[0][1] + .01, est)]
        rings = [est] + miei
        testi = []
        for r in rings:
            pts = [v2ll(v) for v in r] + [v2ll(r[0])]
            testi.append("(" + ", ".join(f"{x:.6f} {y:.6f}" for x, y in pts) + ")")
        parti.append("(" + ", ".join(testi) + ")")
    wkt_zone[z] = "MULTIPOLYGON (" + ", ".join(parti) + ")"
    print(f"zona {z:2}: {len(cs):4} celle, {len(esterni)} parti, {len(buchi)} buchi, wkt {len(wkt_zone[z])} caratteri")

# --- output per la mappa (tutte le celle) e per il DB ---
dati["celleFull"] = [{"cy": cy, "cx": cx, "zona": zz, "attribuita": (cy, cx) not in core}
                     for (cy, cx), zz in sorted(zona_cella.items())]
dati["wkt"] = {str(z): w for z, w in wkt_zone.items()}
with open(BASE + r"\zone_grosseto_full.json", "w", encoding="utf-8") as f:
    json.dump(dati, f, ensure_ascii=False)

# script SQL: SP di inserimento + 16 EXEC (da eseguire SOLO su conferma)
colore = lambda z: f"hsl-{(z - 1) * 137508 % 360000 // 1000}"
def hsl2hex(z):
    import colorsys
    h = ((z - 1) * 137.508 % 360) / 360
    r, gg, b = colorsys.hls_to_rgb(h, 0.45, 0.68)
    return "#{:02X}{:02X}{:02X}".format(int(r * 255), int(gg * 255), int(b * 255))

righe = ["""-- Zone storiche GROSSETO_2 (nov 2019 - mar 2020): memorizzazione degli shape
-- in GEO_GIRI (filiale 31). Generato dalla pipeline zone-storiche; NON eseguire
-- senza conferma: i giri diventano visibili alle pagine operative della filiale.
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
print("scritti zone_grosseto_full.json e zone_grosseto_giri.sql")
