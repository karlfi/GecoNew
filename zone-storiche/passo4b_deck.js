// Passo 4b: deck "Zone storiche di consegna - Filiale Grosseto"
// Progressione: punti 1g / 2g / 1 settimana / 1 mese / periodo -> zone passo 1 -> aree finali.
const pptxgen = require("pptxgenjs");
const FR = "C:/Users/Carlo/AppData/Local/Temp/claude/C--progetti-AI-TWEB/53fa87f8-62f2-4876-98a8-b6325d6172f6/scratchpad/frames/";

const NAVY = "1E2761", ICE = "CADCFC", GRIGIO = "666666", SCURO = "222222";

const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE"; // 13.33 x 7.5

// ---------- titolo ----------
let s = pres.addSlide();
s.background = { color: NAVY };
s.addText("Zone storiche di consegna", {
  x: 0.9, y: 2.3, w: 11.5, h: 1.1, fontSize: 44, bold: true, color: "FFFFFF", fontFace: "Cambria", margin: 0,
});
s.addText("Filiale Grosseto — dai punti di consegna NEXIVE alle aree dei driver", {
  x: 0.9, y: 3.45, w: 11.5, h: 0.6, fontSize: 22, color: ICE, fontFace: "Calibri", margin: 0,
});
s.addText("novembre 2019 – marzo 2020  ·  144.824 consegne geolocalizzate  ·  113 giorni  ·  21 postini", {
  x: 0.9, y: 4.15, w: 11.5, h: 0.5, fontSize: 15, color: "9FB4D8", fontFace: "Calibri", margin: 0,
});

// ---------- slide mappa (immagine sx, pannello dx) ----------
// il frame e' ~1602x1625 -> a tutta altezza (7.5") larghezza ~7.39"
function slideMappa(img, passo, titolo, righe, conLegenda) {
  const sl = pres.addSlide();
  sl.background = { color: "FFFFFF" };
  sl.addImage({ path: FR + img + ".png", x: 0, y: 0, h: 7.5, w: 7.39 });
  sl.addText(passo, {
    x: 7.8, y: 0.55, w: 5.1, h: 0.4, fontSize: 14, bold: true, color: GRIGIO,
    fontFace: "Calibri", charSpacing: 2, margin: 0,
  });
  sl.addText(titolo, {
    x: 7.8, y: 0.95, w: 5.1, h: 1.3, fontSize: 32, bold: true, color: SCURO,
    fontFace: "Cambria", margin: 0,
  });
  let y = 2.35;
  for (const r of righe) {
    if (r.big) {
      sl.addText(r.big, { x: 7.8, y, w: 5.1, h: 0.85, fontSize: 40, bold: true, color: NAVY, fontFace: "Calibri", margin: 0 });
      sl.addText(r.label, { x: 7.8, y: y + 0.8, w: 5.1, h: 0.4, fontSize: 13, color: GRIGIO, fontFace: "Calibri", margin: 0 });
      y += 1.45;
    } else {
      sl.addText(r.testo, { x: 7.8, y, w: 5.1, h: r.h ?? 0.9, fontSize: 14.5, color: "333333", fontFace: "Calibri", margin: 0 });
      y += (r.h ?? 0.9) + 0.15;
    }
  }
  if (conLegenda) {
    // legenda driver 460x312 -> 2.7" x 1.83"
    sl.addImage({ path: FR + "legenda_driver.png", x: 7.8, y: 5.35, w: 2.7, h: 1.83 });
  }
  return sl;
}

const NOTA_COLORI = "Ogni colore è un postino: giorno dopo giorno le aree personali emergono da sole.";

slideMappa("f1_giorno1", "LA PROGRESSIONE — 1 / 5", "Un giorno di consegne", [
  { big: "985", label: "punti di consegna · 4 nov 2019" },
  { testo: NOTA_COLORI, h: 0.7 },
], true);
slideMappa("f2_giorni2", "LA PROGRESSIONE — 2 / 5", "Due giorni", [
  { big: "1.633", label: "punti di consegna · 4–5 nov 2019" },
  { testo: NOTA_COLORI, h: 0.7 },
], true);
slideMappa("f3_settimana", "LA PROGRESSIONE — 3 / 5", "Una settimana", [
  { big: "8.080", label: "punti di consegna · prima settimana" },
  { testo: "Il disegno delle aree comincia a ripetersi: ognuno tiene le sue.", h: 0.7 },
], true);
slideMappa("f4_mese", "LA PROGRESSIONE — 4 / 5", "Un mese", [
  { big: "53.376", label: "punti di consegna · novembre 2019" },
  { testo: "Città divisa a spicchi, campagna a settori: la struttura è già leggibile.", h: 0.7 },
], true);
slideMappa("f5_periodo", "LA PROGRESSIONE — 5 / 5", "Tutto il periodo", [
  { big: "144.824", label: "punti di consegna · nov 2019 – mar 2020" },
  { testo: "Cinque mesi di storia: la base su cui calcolare le zone.", h: 0.7 },
], true);

slideMappa("f6_zone_passo1", "PASSO 1", "Le 16 zone storiche", [
  { big: "16", label: "zone · bilanciate sul carico e contigue" },
  { big: "84,3%", label: "coerenza: quota di punti del driver dominante di zona nel giorno" },
  { testo: "Zone urbane da 76–116 punti/giorno; nelle aree esterne il driver storico è quasi unico (fino al 98–100%).", h: 1.0 },
]);
slideMappa("f7_aree_finali", "PASSI 2 e 3", "Un'area unica per giro", [
  { big: "16", label: "poligoni · uno per giro, senza sovrapposizioni né aree scoperte" },
  { big: "100%", label: "del territorio attribuito: ogni consegna futura cade in un giro preciso" },
  { testo: "Le tinte piene sono le celle con storia; il resto del territorio è attribuito al giro più vicino. Shape pronti per GEO_GIRI.", h: 1.0 },
]);

// ---------- chiusura ----------
s = pres.addSlide();
s.background = { color: NAVY };
s.addText("Prossimi passi", {
  x: 0.9, y: 0.9, w: 11.5, h: 0.9, fontSize: 36, bold: true, color: "FFFFFF", fontFace: "Cambria", margin: 0,
});
const passi = [
  ["1", "Conferma delle zone", "le 16 aree di Grosseto sono in attesa di approvazione definitiva"],
  ["2", "Memorizzazione", "shape in GEO_GIRI della filiale 31 (script SQL già pronto, via SP)"],
  ["3", "Replica", "stessa pipeline sulle altre filiali con storico NEXIVE"],
];
passi.forEach((p, i) => {
  const y = 2.2 + i * 1.5;
  s.addShape("ellipse", { x: 0.95, y: y + 0.05, w: 0.62, h: 0.62, fill: { color: ICE } });
  s.addText(p[0], { x: 0.95, y: y + 0.05, w: 0.62, h: 0.62, align: "center", fontSize: 22, bold: true, color: NAVY, fontFace: "Calibri", margin: 0 });
  s.addText(p[1], { x: 1.85, y, w: 10.3, h: 0.45, fontSize: 20, bold: true, color: "FFFFFF", fontFace: "Calibri", margin: 0 });
  s.addText(p[2], { x: 1.85, y: 0.45 + y, w: 10.3, h: 0.45, fontSize: 14.5, color: "9FB4D8", fontFace: "Calibri", margin: 0 });
});

pres.writeFile({ fileName: "C:/progetti/AI/TWEB/zone-storiche/grosseto/zone-grosseto-v2.pptx" })
  .then(() => console.log("deck scritto"));
