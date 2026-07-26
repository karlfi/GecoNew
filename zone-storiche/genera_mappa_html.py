# -*- coding: utf-8 -*-
# Genera la pagina di presentazione delle zone (Leaflet, celle colorate + etichette)
import json

BASE = r"C:\Users\Carlo\AppData\Local\Temp\claude\C--progetti-AI-TWEB\53fa87f8-62f2-4876-98a8-b6325d6172f6\scratchpad"
import os
percorso = BASE + (r"\zone_grosseto_full.json" if os.path.exists(BASE + r"\zone_grosseto_full.json") else r"\zone_grosseto.json")
dati = json.load(open(percorso, encoding="utf-8"))

html = """<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="utf-8">
<title>Zone storiche GROSSETO_2 — proposta</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
  body { margin: 0; font-family: system-ui, sans-serif; display: flex; height: 100vh; }
  #mappa { flex: 1; }
  #pannello { width: 380px; overflow-y: auto; padding: 12px 16px; border-left: 1px solid #ddd; }
  h1 { font-size: 1.05rem; margin: 0 0 4px; }
  .sotto { color: #666; font-size: .8rem; margin-bottom: 10px; }
  table { border-collapse: collapse; width: 100%; font-size: .78rem; }
  th, td { padding: 3px 6px; text-align: left; border-bottom: 1px solid #eee; }
  th { background: #f7f7f7; position: sticky; top: 0; }
  td.n { text-align: right; }
  .dot { display: inline-block; width: 11px; height: 11px; border-radius: 50%; margin-right: 5px; vertical-align: -1px; }
  .etichetta-zona span {
    display: flex; align-items: center; justify-content: center;
    width: 26px; height: 26px; border-radius: 50%; background: #fff;
    border: 2px solid #333; font-weight: 700; font-size: 13px; box-shadow: 0 1px 4px rgba(0,0,0,.4);
  }
</style>
</head>
<body>
<div id="mappa"></div>
<div id="pannello">
  <h1>Zone storiche — filiale GROSSETO_2</h1>
  <div class="sotto" id="sotto"></div>
  <table id="tab"><thead><tr><th>Zona</th><th class="n">Punti/g</th><th class="n">Celle</th><th>Driver storico</th></tr></thead><tbody></tbody></table>
</div>
<script>
const DATI = __DATI__;
const colore = z => `hsl(${Math.round((z - 1) * 137.508) % 360}, 68%, 45%)`;

document.getElementById('sotto').textContent =
  `nov 2019 – mar 2020 · ${DATI.giorni} giorni · ${DATI.k} zone · coerenza driver ${DATI.coerenza}% · celle ~450 m`;

const mappa = L.map('mappa');
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(mappa);

const g = DATI.griglia;
const bounds = [];

// giri ritagliati sulla provincia (un poligono per giro; anelli extra = buchi)
if (DATI.poligoniProv) {
  for (const [z, polys] of Object.entries(DATI.poligoniProv)) {
    const st = DATI.zone.find(s => s.zona === +z);
    for (const rings of polys) {
      L.polygon(rings, {
        color: colore(+z), weight: 2.5, fillColor: colore(+z), fillOpacity: 0.22
      }).bindTooltip(`giro ${z}${+z === 17 ? ' — ISOLA DEL GIGLIO' : ''}<br>` +
        st.top.map(t => t.pct ? `${t.drv} ${t.pct}%` : t.drv).join(', ')).addTo(mappa);
    }
  }
}

// celle storiche (piene) sopra la tassellatura
for (const c of DATI.celle) {
  const y0 = g.lat0 + c.cy * g.sl, x0 = g.lng0 + c.cx * g.sg;
  const r = L.rectangle([[y0, x0], [y0 + g.sl, x0 + g.sg]], {
    color: colore(c.zona), weight: 0.3, fillColor: colore(c.zona), fillOpacity: 0.55
  }).addTo(mappa);
  const st = DATI.zone[c.zona - 1];
  r.bindTooltip(`zona ${c.zona} — ${c.punti} punti<br>` +
    st.top.map(t => `${t.drv} ${t.pct}%`).join(', '));
  bounds.push([y0, x0], [y0 + g.sl, x0 + g.sg]);
}
mappa.fitBounds(bounds, { padding: [20, 20] });
window.mappa = mappa;

// etichette al baricentro (pesato sui punti) di ogni zona
for (const st of DATI.zone) {
  const cz = DATI.celle.filter(c => c.zona === st.zona);
  let sy = 0, sx = 0, sp = 0;
  for (const c of cz) {
    sy += (g.lat0 + (c.cy + 0.5) * g.sl) * c.punti;
    sx += (g.lng0 + (c.cx + 0.5) * g.sg) * c.punti;
    sp += c.punti;
  }
  L.marker([sy / sp, sx / sp], {
    icon: L.divIcon({ className: 'etichetta-zona', html: `<span style="border-color:${colore(st.zona)}">${st.zona}</span>`, iconSize: [26, 26], iconAnchor: [13, 13] })
  }).addTo(mappa);
}

const tb = document.querySelector('#tab tbody');
for (const st of DATI.zone) {
  const tr = document.createElement('tr');
  tr.innerHTML = `<td><span class="dot" style="background:${colore(st.zona)}"></span>${st.zona}</td>` +
    `<td class="n">${st.puntiGiorno}</td><td class="n">${st.celle}</td>` +
    `<td>${st.top.map(t => `${t.drv} <b>${t.pct}%</b>`).join('<br>')}</td>`;
  tb.appendChild(tr);
}
</script>
</body>
</html>"""

html = html.replace("__DATI__", json.dumps(dati, ensure_ascii=False))
out = r"C:\progetti\AI\TWEB\web\public\zone-grosseto.html"
open(out, "w", encoding="utf-8").write(html)
print("scritto", out)
