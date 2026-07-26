# -*- coding: utf-8 -*-
# Zone storiche GROSSETO_2 v3: come v2 ma con CONTIGUITA' GARANTITA
# (ogni zona = un solo blocco, verificato) e preferenza per meno zone.
import pandas as pd
import numpy as np
import json

BASE = r"C:\Users\Carlo\AppData\Local\Temp\claude\C--progetti-AI-TWEB\53fa87f8-62f2-4876-98a8-b6325d6172f6\scratchpad"
rng = np.random.default_rng(42)

df = pd.read_csv(BASE + r"\siena.csv")
df = df[(df.lat > 43.22) & (df.lat < 43.42) & (df.lng > 11.20) & (df.lng < 11.45)].copy()
df["drv"] = df.postino.str.replace(r"_\d+$", "", regex=True).str.lower()

LAT0, LNG0, SL, SG = 43.22, 11.20, 0.002, 0.00275
df["cy"] = ((df.lat - LAT0) / SL).astype(int)
df["cx"] = ((df.lng - LNG0) / SG).astype(int)
df["cell"] = df.cy * 10000 + df.cx
cnt = df.groupby("cell").size()
# celle-discarica del geocoder (migliaia di consegne non localizzate ammassate
# in un isolato): escluse dal calcolo, l'area verra' comunque attribuita
discarica = cnt[cnt > 20000]
for c, n in discarica.items():
    print(f"cella-discarica esclusa: {c} con {n} punti (geocodifica di ripiego)")
tenute = cnt[(cnt >= 5) & (cnt <= 20000)].index
dfc = df[df.cell.isin(tenute)].copy()
celle = sorted(tenute)
idx = {c: i for i, c in enumerate(celle)}
N = len(celle)
print(f"celle: {N} | punti coperti: {len(dfc)} ({len(dfc)/len(df)*100:.1f}%)")

pesi = cnt.reindex(celle).values.astype(float)
cyv = np.array([c // 10000 for c in celle], dtype=float)
cxv = np.array([c % 10000 for c in celle], dtype=float)
X = np.column_stack([(cxv + .5) * SG * 81.7, (cyv + .5) * SL * 111.32])
TOT = pesi.sum()

# --- co-assegnazione driver-giorno ---
gg = dfc.groupby(["giorno", "cell", "drv"]).size().reset_index(name="n")
gg = gg.sort_values("n", ascending=False).drop_duplicates(["giorno", "cell"])
giorni = sorted(dfc.giorno.unique())
gidx = {g: i for i, g in enumerate(giorni)}
drvs = sorted(dfc.drv.unique())
didx = {d: i for i, d in enumerate(drvs)}
M = np.full((N, len(giorni)), -1, dtype=np.int16)
for r in gg.itertuples():
    M[idx[r.cell], gidx[r.giorno]] = didx[r.drv]
stesso = np.zeros((N, N), dtype=np.int32)
entrambe = np.zeros((N, N), dtype=np.int32)
for d in range(len(giorni)):
    v = M[:, d]
    p = v >= 0
    stesso += (v[:, None] == v[None, :]) & p[:, None] & p[None, :]
    entrambe += p[:, None] & p[None, :]
SIM = np.where(entrambe >= 5, stesso / np.maximum(entrambe, 1), np.nan)

# --- adiacenza a 8 vicini + ponti per i gruppi isolati (isole, frazioni sparse):
# ogni componente staccata del territorio viene collegata alla cella piu' vicina
# del blocco principale, cosi' il grafo e' connesso e le zone possono esserlo ---
ADJ = (np.abs(cyv[:, None] - cyv[None, :]) <= 1) & (np.abs(cxv[:, None] - cxv[None, :]) <= 1)
np.fill_diagonal(ADJ, False)

def componenti(nodi, ad):
    nodi = list(nodi)
    dentro = set(nodi)
    visti, comp = set(), []
    for s in nodi:
        if s in visti:
            continue
        stack, cc = [s], []
        visti.add(s)
        while stack:
            u = stack.pop()
            cc.append(u)
            for v in np.where(ad[u])[0]:
                if v in dentro and v not in visti:
                    visti.add(v)
                    stack.append(v)
        comp.append(cc)
    return comp

terr = componenti(range(N), ADJ)
terr.sort(key=lambda cc: -pesi[cc].sum())
print(f"componenti del territorio: {len(terr)} (principale {len(terr[0])} celle)")
for cc in terr[1:]:
    d2 = ((X[cc][:, None, :] - X[terr[0]][None, :, :]) ** 2).sum(2)
    a, b = np.unravel_index(np.argmin(d2), d2.shape)
    u, v = cc[a], terr[0][b]
    ADJ[u, v] = ADJ[v, u] = True
NEIGH = [np.where(ADJ[i])[0] for i in range(N)]

def n_comp_zona(zona, z):
    memb = np.where(zona == z)[0]
    return len(componenti(memb, ADJ)) if len(memb) else 0

def kmeans_bilanciato(k):
    # crescita bilanciata di regioni contigue: k semi sparsi, a ogni passo la
    # zona piu' leggera assorbe la cella libera adiacente piu' affine
    centri = [int(rng.choice(N, p=pesi / TOT))]
    for _ in range(k - 1):
        d2 = np.min(np.stack([((X - X[c]) ** 2).sum(1) for c in centri]), axis=0)
        pr = d2 * pesi
        centri.append(int(rng.choice(N, p=pr / pr.sum())))
    zona = np.full(N, -1)
    load = np.zeros(k)
    for z, c in enumerate(centri):
        zona[c] = z
        load[z] = pesi[c]
    aperte = set(range(k))
    n_ass = k
    while n_ass < N and aperte:
        z = min(aperte, key=lambda z: load[z])
        memb = np.where(zona == z)[0]
        frontiera = {v for u in memb for v in NEIGH[u] if zona[v] == -1}
        if not frontiera:
            aperte.discard(z)
            continue
        def punteggio(c):
            s = SIM[c, memb]
            s = s[~np.isnan(s)]
            aff = s.mean() if len(s) else 0.4
            dmin = min(((X[c] - X[u]) ** 2).sum() for u in memb)
            return aff - 0.02 * dmin
        c = max(frontiera, key=punteggio)
        zona[c] = z
        load[z] += pesi[c]
        n_ass += 1
    # celle rimaste orfane (zone chiuse): alla zona adiacente piu' leggera
    while (zona == -1).any():
        for c in np.where(zona == -1)[0]:
            vz = {zona[v] for v in NEIGH[c] if zona[v] >= 0}
            if vz:
                z = min(vz, key=lambda z: load[z])
                zona[c] = z
                load[z] += pesi[c]
    return zona

def forza_contiguita(zona, k):
    # ogni zona deve restare un solo blocco: le componenti secondarie passano,
    # cella per cella, alla zona adiacente piu' presente; si ripete fino a pulito
    for _ in range(40):
        rotte = [z for z in range(k) if n_comp_zona(zona, z) > 1]
        if not rotte:
            return zona
        for z in rotte:
            memb = np.where(zona == z)[0]
            comp = componenti(memb, ADJ)
            comp.sort(key=lambda cc: -pesi[cc].sum())
            for cc in comp[1:]:
                for u in sorted(cc, key=lambda u: -len([v for v in NEIGH[u] if zona[v] != z])):
                    vz = [zona[v] for v in NEIGH[u] if zona[v] != z]
                    if vz:
                        zona[u] = np.bincount(vz).argmax()
    return zona

def zona_connessa_senza(zona, z, c):
    memb = [u for u in np.where(zona == z)[0] if u != c]
    if not memb:
        return False
    return len(componenti(memb, ADJ)) == 1

def rifinisci_affinita(zona, k):
    cap = TOT / k * 1.4
    load = np.array([pesi[zona == z].sum() for z in range(k)])
    for _ in range(3):
        cambi = 0
        for c in range(N):
            z0 = zona[c]
            vic = np.unique([zona[v] for v in NEIGH[c]])
            vic = [z for z in vic if z != z0]
            if not vic:
                continue
            def aff(z):
                m = (zona == z)
                m[c] = False
                s = SIM[c, m]
                s = s[~np.isnan(s)]
                return s.mean() if len(s) else -1
            a0 = aff(z0)
            best, bz = a0, z0
            for z in vic:
                a = aff(z)
                if a > best + 0.03 and load[z] + pesi[c] <= cap:
                    best, bz = a, z
            # lo spostamento non deve spezzare la zona di partenza
            if bz != z0 and zona_connessa_senza(zona, z0, c):
                zona[c] = bz
                load[z0] -= pesi[c]
                load[bz] += pesi[c]
                cambi += 1
        if cambi == 0:
            break
    return zona

def valuta(zona, k):
    tmp = dfc.copy()
    tmp["zona"] = tmp.cell.map({celle[c]: zona[c] for c in range(N)})
    dom = tmp.groupby(["giorno", "zona", "drv"]).size().reset_index(name="n")
    tot = dom.groupby(["giorno", "zona"]).n.sum()
    mx = dom.groupby(["giorno", "zona"]).n.max()
    coer = mx.sum() / tot.sum()
    load = np.array([pesi[zona == z].sum() for z in range(k)])
    load = load[load > 0]
    sbil = load.std() / load.mean()
    return coer, sbil, coer - 0.15 * sbil

ris = {}
for k in range(10, 21):
    z = kmeans_bilanciato(k)
    z = forza_contiguita(z, k)
    z = rifinisci_affinita(z, k)
    z = forza_contiguita(z, k)
    ncz = [n_comp_zona(z, zz) for zz in range(k) if (z == zz).any()]
    coer, sbil, score = valuta(z, k)
    ris[k] = (z.copy(), coer, sbil, score, max(ncz))
    print(f"k={k:2}  coerenza={coer*100:5.1f}%  sbilanc.={sbil:.2f}  punteggio={score:.3f}  maxComponenti={max(ncz)}")

# parsimonia: il k piu' piccolo entro 0.02 dal punteggio migliore, tra i contigui
validi = {k: v for k, v in ris.items() if v[4] == 1}
best = max(v[3] for v in validi.values())
K = min(k for k, v in validi.items() if v[3] >= best - 0.02)
zona, coer, sbil, _, _ = ris[K]
print(f"\nscelto k={K} (coerenza {coer*100:.1f}%, sbilanciamento {sbil:.2f})")

# verifica finale dura
for z in range(K):
    if (zona == z).any():
        assert n_comp_zona(zona, z) == 1, f"zona {z} NON contigua!"
print("verifica contiguita': tutte le zone sono un blocco unico")

ordine = np.argsort([-pesi[zona == z].sum() for z in range(K)])
rin = {int(old): i + 1 for i, old in enumerate(ordine)}
zfin = np.array([rin[z] for z in zona])

dfc["zona"] = dfc.cell.map({celle[c]: int(zfin[c]) for c in range(N)})
stat = []
nz = len(set(zfin))
for z in range(1, nz + 1):
    dz = dfc[dfc.zona == z]
    top = dz.groupby("drv").size().sort_values(ascending=False)
    tot = len(dz)
    stat.append({
        "zona": z, "celle": int((zfin == z).sum()), "punti": int(tot),
        "puntiGiorno": round(tot / len(giorni), 1),
        "top": [{"drv": d, "pct": round(n / tot * 100)} for d, n in top.head(3).items()],
    })
    print(f"  zona {z:2}: {(zfin==z).sum():3} celle, {tot:6} punti ({tot/len(giorni):6.1f}/g), "
          + ", ".join(f"{t['drv']} {t['pct']}%" for t in stat[-1]["top"]))

out = {
    "griglia": {"lat0": LAT0, "lng0": LNG0, "sl": SL, "sg": SG},
    "k": nz, "giorni": len(giorni), "coerenza": round(coer * 100, 1),
    "celle": [{"cy": int(cyv[c]), "cx": int(cxv[c]), "zona": int(zfin[c]), "punti": int(pesi[c])} for c in range(N)],
    "zone": stat,
}
with open(BASE + r"\zone_siena.json", "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False)
print("scritto zone_siena.json")
