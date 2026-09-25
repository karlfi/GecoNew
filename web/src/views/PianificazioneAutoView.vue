<script setup>
// Pianificazione automatica: tutte le spedizioni geolocalizzate della filiale nel giorno scelto divise fra i driver
// selezionati con HERE Tour Planning, ottimizzando i percorsi e bilanciando il carico (api/PianoAuto.cs).
// Sopra: giorno, riepilogo, parametri (sosta, equilibrio, zone abituali), "Calcola", avanzamento, esito e conferma.
// A sinistra i driver: si scelgono e per ognuno si regolano turno, partenza e ritorno (filiale o casa), massimo di
// pezzi e zone preferite (i giri che fa di solito: HERE lo tiene li' ma puo' dargli consegne fuori per bilanciare).
// A destra la mappa: prima del calcolo i punti colorati per giro, dopo il calcolo per driver con il percorso;
// clic su un driver = solo il suo giro, con le tappe numerate. Le non assegnate sono elencate sotto la mappa col motivo.
// Il calcolo lo fa lo schedulatore (workflow GEO-02_HERE_TOUR): la pagina ne segue lo stato. Confermando, la sequenza
// di consegna va sulle spedizioni; i giri non cambiano.
import { ref, reactive, computed, onMounted, onBeforeUnmount, watch } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { scaricaDaApi } from '../lib/esporta'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import Button from 'primevue/button'
import DatePicker from 'primevue/datepicker'
import Checkbox from 'primevue/checkbox'
import InputNumber from 'primevue/inputnumber'
import SelectButton from 'primevue/selectbutton'
import MultiSelect from 'primevue/multiselect'
import ToggleSwitch from 'primevue/toggleswitch'
import ProgressBar from 'primevue/progressbar'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Dialog from 'primevue/dialog'

const toast = useToast()
const avviso = (severity, summary, detail, life = 4000) => toast.add({ severity, summary, detail, life })
const messaggio = e => e?.response?.data?.errore ?? e?.message ?? 'Errore'
const km = m => m == null ? '—' : `${(m / 1000).toFixed(1)} km`
const durata = s => s == null ? '—' : s >= 3600 ? `${Math.floor(s / 3600)} h ${String(Math.round((s % 3600) / 60)).padStart(2, '0')}` : `${Math.round(s / 60)} min`
const ora = v => v ? String(v).slice(11, 16) : ''
const trascorso = s => s == null ? '' : s >= 60 ? `${Math.floor(s / 60)} min ${s % 60} s` : `${s} s`
const PALETTE = ['#e6194b', '#3cb44b', '#4363d8', '#f58231', '#911eb4', '#008080', '#f032e6', '#9a6324', '#800000', '#469990',
  '#000075', '#808000', '#e6a100', '#1e88e5', '#c2185b', '#43a047', '#6d4c41', '#5e35b1', '#00897b', '#d84315']
const STATI = {
  RICHIESTA: { testo: 'in coda', sev: 'info' }, IN_CORSO: { testo: 'in calcolo', sev: 'info' },
  CALCOLATO: { testo: 'da confermare', sev: 'warn' }, ERRORE: { testo: 'errore', sev: 'danger' },
  CONFERMATO: { testo: 'confermato', sev: 'success' }, SCARTATO: { testo: 'scartato', sev: 'secondary' },
  SUPERATO: { testo: 'superato', sev: 'secondary' },
}
const opzioniLuogo = [{ label: 'Filiale', value: false }, { label: 'Casa', value: true }]

// --- dati ---
const data = ref(new Date())
const dataIso = computed(() => {
  const d = data.value instanceof Date ? data.value : new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
})
const info = ref(null)
const righe = ref([])              // driver: { idUtente, nome, sel, inizio, fine, partenzaCasa, ritornoCasa, maxPezzi, giri, colore, casa, aperto }
const punti = ref([])
const piano = ref(null)
const stato = ref(null)            // avanzamento del calcolo
const caricamento = ref(false)
const lavoro = ref(false)
const scelto = ref(null)           // driver evidenziato sulla mappa
const conferma = ref(false)
const parametri = reactive({ sosta: 60, sostaPezzo: 20, tolleranza: 15, zone: true, usaTutti: true })

const giri = computed(() => info.value?.giri ?? [])
const giroPer = computed(() => new Map(giri.value.map(g => [g.idGiro, g])))
const selezionati = computed(() => righe.value.filter(r => r.sel))
const inCalcolo = computed(() => ['RICHIESTA', 'IN_CORSO'].includes(piano.value?.stato))
const conRisultato = computed(() => ['CALCOLATO', 'CONFERMATO', 'SUPERATO', 'SCARTATO'].includes(piano.value?.stato))
const risultatoDi = computed(() => new Map((piano.value?.driver ?? []).map(d => [d.idDriver, d])))
const colorePer = computed(() => new Map(righe.value.map(r => [r.idUtente, r.colore])))
const nonAssegnati = computed(() => conRisultato.value ? punti.value.filter(p => p.nelPiano && !p.idDriver) : [])
const nuoviDopo = computed(() => conRisultato.value ? punti.value.filter(p => !p.nelPiano).length : 0)
const mediaPezzi = computed(() => selezionati.value.length ? Math.round((info.value?.riepilogo?.nGeo ?? 0) / selezionati.value.length) : 0)

async function carica() {
  caricamento.value = true
  fermaAttesa()
  try {
    const { data: r } = await api.get('/pianificazione', { params: { data: dataIso.value } })
    info.value = r
    piano.value = r.piano
    let p = {}
    try { p = JSON.parse(r.piano?.parametri || r.parametri || '{}') || {} } catch { p = {} }
    Object.assign(parametri, { sosta: r.sostaPredefinita ?? 60, sostaPezzo: 20, tolleranza: 15, zone: true, usaTutti: true }, p)
    const delPiano = new Map((r.piano?.driver ?? []).map(d => [d.idDriver, d]))
    righe.value = r.driver.map((d, i) => {
      const pd = delPiano.get(d.idUtente)
      const giriJson = pd?.giriJson ?? d.giriJson
      let giriScelti = []
      try { giriScelti = giriJson ? JSON.parse(giriJson) : [] } catch { giriScelti = [] }
      if (!giriJson && d.giriAbituali) giriScelti = d.giriAbituali.split(',').map(Number)
      return {
        idUtente: d.idUtente, nome: d.nome,
        sel: r.piano ? !!pd : (!!d.nellUltimo || !!d.giriAbituali),
        inizio: pd?.inizio ?? d.inizio ?? '08:30', fine: pd?.fine ?? d.fine ?? '15:30',
        partenzaCasa: !!(pd?.partenzaCasa ?? d.partenzaCasa), ritornoCasa: !!(pd?.ritornoCasa ?? d.ritornoCasa),
        maxPezzi: pd?.maxPezzi ?? d.maxPezzi ?? null, giri: giriScelti,
        colore: pd?.colore ?? PALETTE[i % PALETTE.length],
        casa: d.casaLat != null ? { lat: d.casaLat, lng: d.casaLng, indirizzo: d.casaIndirizzo } : null,
        aperto: false,
      }
    })
    scelto.value = null
    await caricaPunti()
    if (inCalcolo.value) attendi()
  } catch (e) {
    avviso('error', 'Pianificazione', messaggio(e), 6000)
  } finally {
    caricamento.value = false
  }
}

async function caricaPunti() {
  const { data: r } = await api.get('/pianificazione/punti', { params: { data: dataIso.value, idPiano: piano.value?.idPiano } })
  punti.value = r
  disegna(true)
}

// --- calcolo ---
function controlla() {
  if (!selezionati.value.length) return 'Scegli almeno un driver'
  for (const r of selezionati.value) {
    if (!r.inizio || !r.fine || r.fine <= r.inizio) return `${r.nome}: la fine turno deve essere dopo l'inizio`
    if ((r.partenzaCasa || r.ritornoCasa) && !r.casa) return `${r.nome}: la casa non e' impostata (si imposta in Piano della giornata)`
  }
  if (!info.value?.riepilogo?.nGeo) return 'Nessuna spedizione geolocalizzata in questo giorno'
  return null
}
async function calcola() {
  const err = controlla()
  if (err) { avviso('warn', 'Calcola', err); return }
  lavoro.value = true
  try {
    const { data: r } = await api.post('/pianificazione/calcola', {
      data: dataIso.value,
      parametri: { ...parametri },
      driver: selezionati.value.map(x => ({
        idDriver: x.idUtente, inizio: x.inizio, fine: x.fine, partenzaCasa: x.partenzaCasa, ritornoCasa: x.ritornoCasa,
        maxPezzi: x.maxPezzi || null, giri: x.giri, colore: x.colore,
      })),
    })
    piano.value = { idPiano: r.idPiano, stato: 'RICHIESTA', driver: [] }
    stato.value = { stato: 'RICHIESTA', secondi: 0 }
    scelto.value = null
    await caricaPunti()
    attendi()
  } catch (e) {
    avviso('error', 'Calcola', messaggio(e), 6000)
  } finally {
    lavoro.value = false
  }
}
let timer = null
function fermaAttesa() { clearTimeout(timer); timer = null }
function attendi() {
  fermaAttesa()
  timer = setTimeout(async () => {
    if (!piano.value?.idPiano) return
    try {
      const { data: s } = await api.get(`/pianificazione/${piano.value.idPiano}/stato`)
      stato.value = s
      if (['RICHIESTA', 'IN_CORSO'].includes(s.stato)) { piano.value.stato = s.stato; attendi(); return }
      const { data: p } = await api.get(`/pianificazione/${piano.value.idPiano}`)
      piano.value = p
      await caricaPunti()
      if (p.stato === 'CALCOLATO') avviso('success', 'Pianificazione', `Calcolo pronto: ${p.nAssegnate} pezzi assegnati${p.nNonAssegnate ? `, ${p.nNonAssegnate} non assegnati` : ''}`)
      else if (p.stato === 'ERRORE') avviso('error', 'Pianificazione', p.errore || 'Calcolo non riuscito', 8000)
    } catch (e) {
      attendi()
    }
  }, 3000)
}
const testoAvanzamento = computed(() => {
  const s = stato.value
  if (!s || piano.value?.stato === 'RICHIESTA') return `In coda nello schedulatore${s?.secondi ? ` da ${trascorso(s.secondi)}` : ''}…`
  return `HERE sta calcolando i giri (di solito 2-3 minuti): ${trascorso(s.secondi)}`
})

async function azione(tipo) {
  lavoro.value = true
  try {
    const { data: p } = await api.post(`/pianificazione/${piano.value.idPiano}/${tipo}`)
    piano.value = p
    conferma.value = false
    avviso('success', 'Pianificazione', tipo === 'conferma' ? 'Piano confermato: la sequenza di consegna e\' sulle spedizioni' : 'Piano scartato')
    disegna(false)
  } catch (e) {
    avviso('error', 'Pianificazione', messaggio(e), 6000)
  } finally {
    lavoro.value = false
  }
}
function esporta(r) {
  scaricaDaApi(api, `/pianificazione/${piano.value.idPiano}/driver/${r.idUtente}/export`, null, `pianificazione_${r.nome}.xlsx`)
}
function tutti(v) { righe.value.forEach(r => { r.sel = v }) }
function evidenzia(r) { scelto.value = scelto.value === r.idUtente ? null : r.idUtente }
watch(scelto, () => disegna(false))
watch(dataIso, () => carica())

// --- mappa ---
let map = null, resizeObs = null, puntiLayer, percorsiLayer, basiLayer
const mapEl = ref(null)
function preparaMappa() {
  map = L.map(mapEl.value, { center: [43.84, 11.11], zoom: 11 })
  const osm = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map)
  const satellite = L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', { maxZoom: 19, attribution: 'Tiles © Esri' })
  L.control.layers({ Mappa: osm, Satellite: satellite }, null, { position: 'topright' }).addTo(map)
  percorsiLayer = L.layerGroup().addTo(map)
  puntiLayer = L.featureGroup().addTo(map)
  basiLayer = L.layerGroup().addTo(map)
  resizeObs = new ResizeObserver(() => map && map.invalidateSize())
  resizeObs.observe(mapEl.value)
  setTimeout(() => map && map.invalidateSize(), 200)
}
const esc = t => String(t ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])
function descrizione(p) {
  const drv = p.idDriver ? righe.value.find(r => r.idUtente === p.idDriver)?.nome : null
  return `<b>${esc(p.destinatario)}</b><br>${esc(p.indirizzo)} — ${esc(p.cap)} ${esc(p.localita)}` +
    (p.idGiro ? `<br>giro ${esc(giroPer.value.get(p.idGiro)?.giro ?? p.idGiro)}` : '') +
    (drv ? `<br>${esc(drv)}: consegna ${p.sequenza}${p.arrivo ? `, arrivo ${ora(p.arrivo)}` : ''}` : '') +
    (p.motivo ? `<br><span style="color:#c62828">${esc(p.motivo)}</span>` : '')
}
function disegna(adatta) {
  if (!map) return
  puntiLayer.clearLayers(); percorsiLayer.clearLayers(); basiLayer.clearLayers()
  const base = info.value?.filiale
  if (base?.lat != null) {
    L.marker([base.lat, base.lng], { icon: L.divIcon({ className: 'pa-base', html: '<span>F</span>', iconSize: [26, 26] }), zIndexOffset: 1000 })
      .bindTooltip(esc(base.nome)).addTo(basiLayer)
  }
  const risultato = conRisultato.value
  for (const p of punti.value) {
    let colore = '#9e9e9e', raggio = 5, opacita = 0.9
    if (risultato && p.nelPiano) {
      colore = p.idDriver ? (colorePer.value.get(p.idDriver) ?? '#555') : '#c62828'
      if (!p.idDriver) raggio = 7
      if (scelto.value && p.idDriver !== scelto.value) { opacita = 0.18 }
    } else if (!risultato) {
      colore = giroPer.value.get(p.idGiro)?.colore || '#9e9e9e'
    }
    L.circleMarker([p.lat, p.lng], { radius: raggio, color: '#333', weight: 1, fillColor: colore, fillOpacity: opacita, opacity: opacita })
      .bindTooltip(descrizione(p)).addTo(puntiLayer)
  }
  if (risultato) {
    for (const r of righe.value) {
      const mie = punti.value.filter(p => p.idDriver === r.idUtente).sort((a, b) => a.sequenza - b.sequenza)
      if (!mie.length) continue
      const pd = risultatoDi.value.get(r.idUtente)
      const partenza = pd?.partenzaCasa && r.casa ? [r.casa.lat, r.casa.lng] : [base?.lat, base?.lng]
      const arrivo = pd?.ritornoCasa && r.casa ? [r.casa.lat, r.casa.lng] : [base?.lat, base?.lng]
      const tappe = []
      let ultimaFermata = null
      for (const p of mie) { if (p.fermata !== ultimaFermata) { tappe.push(p); ultimaFermata = p.fermata } }
      const linea = [partenza, ...tappe.map(p => [p.lat, p.lng]), arrivo].filter(x => x[0] != null)
      const attivo = !scelto.value || scelto.value === r.idUtente
      L.polyline(linea, { color: r.colore, weight: attivo ? 3 : 1, opacity: attivo ? 0.85 : 0.15 }).addTo(percorsiLayer)
      if (r.casa && (pd?.partenzaCasa || pd?.ritornoCasa)) {
        L.marker([r.casa.lat, r.casa.lng], { icon: L.divIcon({ className: 'pa-casa', html: `<span style="background:${r.colore}">⌂</span>`, iconSize: [20, 20] }) })
          .bindTooltip(`Casa di ${esc(r.nome)}`).addTo(basiLayer)
      }
      if (scelto.value === r.idUtente) {
        tappe.forEach((p, i) => L.marker([p.lat, p.lng], { icon: L.divIcon({ className: 'pa-tappa', html: `<span style="background:${r.colore}">${i + 1}</span>`, iconSize: [22, 22] }) })
          .bindTooltip(descrizione(p)).addTo(basiLayer))
      }
    }
  }
  if (adatta && punti.value.length) {
    const b = puntiLayer.getBounds()
    if (b.isValid()) map.fitBounds(b.pad(0.05))
  }
}

onMounted(async () => { preparaMappa(); await carica() })
onBeforeUnmount(() => { fermaAttesa(); resizeObs?.disconnect(); if (map) { map.remove(); map = null } })
</script>

<template>
  <div class="pagina">
    <!-- sopra: giorno, riepilogo, parametri, calcola, avanzamento ed esito -->
    <div class="testata">
      <div>
        <h2>Pianificazione automatica <span class="filiale">{{ info?.filiale?.nome }}</span></h2>
        <p class="sotto">Divide le spedizioni del giorno fra i driver scelti con HERE: percorsi ottimizzati, carico bilanciato,
          ognuno di preferenza nelle sue zone abituali. Il piano si conferma per scrivere la sequenza di consegna; i giri non cambiano.</p>
      </div>
      <div class="barra">
        <DatePicker v-model="data" dateFormat="dd/mm/yy" showIcon class="data" />
        <Button icon="pi pi-refresh" text rounded title="Ricarica" :loading="caricamento" @click="carica" />
      </div>
    </div>

    <div class="comandi">
      <div class="riepilogo">
        <span class="chip">{{ info?.riepilogo?.nSped ?? 0 }} spedizioni</span>
        <span class="chip ok">{{ info?.riepilogo?.nGeo ?? 0 }} geolocalizzate</span>
        <span v-if="(info?.riepilogo?.nSped ?? 0) > (info?.riepilogo?.nGeo ?? 0)" class="chip attenzione"
          title="Senza coordinate non entrano nel calcolo: si sistemano in Spedizioni del giorno">
          {{ info.riepilogo.nSped - info.riepilogo.nGeo }} senza coordinate</span>
        <span class="chip">{{ info?.riepilogo?.nFermate ?? 0 }} indirizzi</span>
        <span class="chip">{{ selezionati.length }} driver<template v-if="mediaPezzi"> · ~{{ mediaPezzi }} pezzi a testa</template></span>
      </div>
      <div class="parametri">
        <label title="Secondi per fermata">Sosta <InputNumber v-model="parametri.sosta" :min="10" :max="900" suffix=" s" inputClass="num" /></label>
        <label title="Secondi in piu' per ogni pezzo oltre il primo allo stesso indirizzo">+ per pezzo <InputNumber v-model="parametri.sostaPezzo" :min="0" :max="300" suffix=" s" inputClass="num" /></label>
        <label title="Quanto un driver puo' scostarsi dalla media di pezzi e di fermate (0 = nessun vincolo di equilibrio)">Equilibrio ±
          <InputNumber v-model="parametri.tolleranza" :min="0" :max="100" suffix=" %" inputClass="num" /></label>
        <label title="Ogni driver lavora di preferenza nelle sue zone (i giri scelti nella sua scheda)"><ToggleSwitch v-model="parametri.zone" /> Zone abituali</label>
        <label title="Fa lavorare tutti i driver scelti invece di usarne il meno possibile"><ToggleSwitch v-model="parametri.usaTutti" /> Usa tutti i driver</label>
        <span class="spazio"></span>
        <Button label="Calcola" icon="pi pi-cog" :loading="lavoro && !conRisultato" :disabled="inCalcolo || caricamento || !selezionati.length" @click="calcola" />
      </div>
      <div v-if="inCalcolo" class="avanzamento">
        <ProgressBar mode="indeterminate" style="height: 6px" />
        <small>{{ testoAvanzamento }}</small>
      </div>
      <div v-else-if="piano" class="esito">
        <Tag :value="STATI[piano.stato]?.testo ?? piano.stato" :severity="STATI[piano.stato]?.sev" />
        <template v-if="conRisultato">
          <span class="chip ok">{{ piano.nAssegnate }} pezzi assegnati</span>
          <span v-if="piano.nNonAssegnate" class="chip attenzione">{{ piano.nNonAssegnate }} non assegnati</span>
          <span class="chip">{{ piano.nFermate }} fermate</span>
          <span class="chip">{{ km(piano.distanzaM) }}</span>
          <span class="chip">{{ durata(piano.tempoS) }} di lavoro in tutto</span>
          <span v-if="nuoviDopo" class="chip attenzione" title="Spedizioni arrivate dopo il calcolo: ricalcolare per includerle">{{ nuoviDopo }} arrivate dopo il calcolo</span>
        </template>
        <Message v-if="piano.stato === 'ERRORE'" severity="error" :closable="false" class="errore">{{ piano.errore }}</Message>
        <span class="spazio"></span>
        <small v-if="piano.stato === 'CONFERMATO'" class="nota">confermato {{ piano.utenteConferma ? `da ${piano.utenteConferma}` : '' }}</small>
        <template v-if="piano.stato === 'CALCOLATO'">
          <Button label="Scarta" icon="pi pi-times" text severity="secondary" :disabled="lavoro" @click="azione('scarta')" />
          <Button label="Conferma" icon="pi pi-check" severity="success" :disabled="lavoro" @click="conferma = true" />
        </template>
      </div>
    </div>

    <div class="lavagna">
      <!-- sinistra: i driver con i loro vincoli e, dopo il calcolo, i risultati -->
      <div class="colonna sinistra">
        <div class="titolo-col">
          <span>Driver <small class="nota">({{ selezionati.length }} su {{ righe.length }})</small></span>
          <span class="spazio"></span>
          <Button label="tutti" text size="small" @click="tutti(true)" />
          <Button label="nessuno" text size="small" @click="tutti(false)" />
        </div>
        <div class="elenco">
          <div v-for="r in righe" :key="r.idUtente" class="driver" :class="{ spento: !r.sel, scelto: scelto === r.idUtente }">
            <div class="riga-driver">
              <Checkbox v-model="r.sel" binary :disabled="inCalcolo" />
              <span class="pallino" :style="{ background: r.colore }"></span>
              <span class="nome" :title="conRisultato ? 'Mostra solo il suo giro sulla mappa' : ''" @click="conRisultato && evidenzia(r)">{{ r.nome }}</span>
              <Button :icon="r.aperto ? 'pi pi-chevron-up' : 'pi pi-sliders-h'" text rounded size="small" title="Turno, partenza, massimo pezzi, zone"
                @click="r.aperto = !r.aperto" />
            </div>
            <div v-if="conRisultato && risultatoDi.get(r.idUtente)" class="risultato">
              <template v-if="risultatoDi.get(r.idUtente).nPezzi">
                <b>{{ risultatoDi.get(r.idUtente).nPezzi }}</b> pezzi · {{ risultatoDi.get(r.idUtente).nFermate }} fermate ·
                {{ km(risultatoDi.get(r.idUtente).distanzaM) }} · {{ durata(risultatoDi.get(r.idUtente).tempoS) }} ·
                fine {{ ora(risultatoDi.get(r.idUtente).oraFine) }}
                <Button icon="pi pi-file-excel" text rounded size="small" title="Il giro in Excel" @click="esporta(r)" />
              </template>
              <span v-else class="attenzione">nessuna consegna assegnata</span>
            </div>
            <div v-else class="sintesi">{{ r.inizio }}–{{ r.fine }} · {{ r.partenzaCasa ? 'da casa' : 'da filiale' }}
              <template v-if="r.maxPezzi"> · max {{ r.maxPezzi }}</template>
              <template v-if="r.giri.length"> · {{ r.giri.length }} {{ r.giri.length === 1 ? 'zona' : 'zone' }}</template></div>
            <div v-if="r.aperto" class="dettaglio">
              <label>Turno
                <span class="orari"><input v-model="r.inizio" type="time" class="p-inputtext ora" /> –
                  <input v-model="r.fine" type="time" class="p-inputtext ora" /></span></label>
              <label>Partenza <SelectButton v-model="r.partenzaCasa" :options="opzioniLuogo" optionLabel="label" optionValue="value"
                :optionDisabled="o => o.value && !r.casa" :allowEmpty="false" size="small" /></label>
              <label>Ritorno <SelectButton v-model="r.ritornoCasa" :options="opzioniLuogo" optionLabel="label" optionValue="value"
                :optionDisabled="o => o.value && !r.casa" :allowEmpty="false" size="small" /></label>
              <small v-if="!r.casa" class="nota">casa non impostata: si imposta in Piano della giornata</small>
              <label>Massimo pezzi <InputNumber v-model="r.maxPezzi" :min="1" :max="999" placeholder="nessuno" inputClass="num" /></label>
              <label>Zone abituali
                <MultiSelect v-model="r.giri" :options="giri" optionLabel="giro" optionValue="idGiro" filter display="chip"
                  placeholder="nessuna" :maxSelectedLabels="4" class="zone" /></label>
            </div>
          </div>
          <p v-if="!righe.length && !caricamento" class="nota">Nessun driver in questa filiale.</p>
        </div>
      </div>

      <!-- destra: la mappa e le non assegnate -->
      <div class="colonna destra">
        <div ref="mapEl" class="mappa"></div>
        <div v-if="nonAssegnati.length" class="non-assegnate">
          <div class="titolo-col"><span>Non assegnate ({{ nonAssegnati.length }})</span></div>
          <div v-for="p in nonAssegnati" :key="p.id" class="na">
            <span class="mono">{{ p.barcode }}</span> {{ p.destinatario }} — {{ p.indirizzo }}, {{ p.localita }}
            <span class="attenzione">{{ p.motivo }}</span>
          </div>
        </div>
      </div>
    </div>

    <Dialog v-model:visible="conferma" modal header="Confermare il piano?" :style="{ width: '30rem' }">
      <p>La sequenza di consegna di ogni driver viene scritta sulle spedizioni del {{ dataIso.split('-').reverse().join('/') }}.
        <template v-if="piano?.nNonAssegnate"> {{ piano.nNonAssegnate }} spedizioni restano senza driver.</template>
        Un piano confermato prima per lo stesso giorno viene sostituito.</p>
      <template #footer>
        <Button label="Annulla" text @click="conferma = false" />
        <Button label="Conferma" icon="pi pi-check" severity="success" :loading="lavoro" @click="azione('conferma')" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: .5rem; height: calc(100vh - 7rem); min-height: 640px; }
.testata { display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
.testata h2 { margin: 0; }
.filiale { font-weight: 400; color: var(--p-text-muted-color); font-size: 1rem; margin-left: .5rem; }
.sotto { margin: .15rem 0 0; color: var(--p-text-muted-color); font-size: .85rem; max-width: 70rem; }
.barra { display: flex; align-items: center; gap: .5rem; }
.data { width: 9.5rem; }
.comandi { display: flex; flex-direction: column; gap: .45rem; border: 1px solid var(--p-surface-200); border-radius: 8px; padding: .55rem .7rem; background: var(--p-surface-50); }
.riepilogo, .parametri, .esito { display: flex; align-items: center; gap: .5rem .9rem; flex-wrap: wrap; }
.parametri label { display: inline-flex; align-items: center; gap: .35rem; font-size: .85rem; color: #555; }
:deep(.num) { width: 4.8rem; padding: .3rem .45rem; }
.avanzamento { display: flex; flex-direction: column; gap: .25rem; }
.avanzamento small { color: var(--p-text-muted-color); }
.errore { margin: 0; }
.chip { border: 1px solid var(--p-surface-300); background: var(--p-surface-0); border-radius: 999px; padding: .2rem .7rem; font-size: .85rem; }
.chip.ok { color: #1a7a1a; border-color: #1a7a1a; }
.chip.attenzione { color: var(--p-orange-600); border-color: var(--p-orange-400); }
.nota { color: var(--p-text-muted-color); font-size: .82rem; }
.attenzione { color: var(--p-orange-600); font-size: .82rem; }
.spazio { flex: 1; }
.mono { font-family: monospace; }
.lavagna { display: grid; grid-template-columns: 24rem 1fr; gap: .75rem; flex: 1; min-height: 0; }
.colonna { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
.titolo-col { display: flex; align-items: center; gap: .25rem; font-weight: 600; padding: .1rem .2rem .3rem; }
.elenco { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: .35rem; padding-right: .2rem; }
.driver { border: 1px solid var(--p-surface-200); border-radius: 6px; padding: .3rem .45rem; background: var(--p-surface-0); }
.driver.spento { opacity: .55; }
.driver.scelto { border-color: var(--p-primary-color); box-shadow: 0 0 0 1px var(--p-primary-color); }
.riga-driver { display: flex; align-items: center; gap: .4rem; }
.pallino { display: inline-block; width: 11px; height: 11px; border-radius: 50%; border: 1px solid #999; flex: none; }
.nome { flex: 1; font-weight: 500; cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.sintesi, .risultato { font-size: .8rem; color: #555; padding-left: 1.9rem; display: flex; align-items: center; flex-wrap: wrap; gap: .15rem; }
.dettaglio { display: flex; flex-direction: column; gap: .4rem; padding: .45rem 0 .2rem 1.9rem; }
.dettaglio label { display: flex; flex-direction: column; gap: .2rem; font-size: .8rem; color: #555; }
.orari { display: flex; align-items: center; gap: .35rem; }
.ora { width: 6.5rem; padding: .3rem .45rem; }
.zone { width: 100%; }
.mappa { flex: 1; min-height: 320px; border: 1px solid var(--p-surface-300); border-radius: 6px; z-index: 0; }
.non-assegnate { max-height: 26%; overflow-y: auto; border: 1px solid var(--p-surface-200); border-radius: 6px; margin-top: .4rem; padding: .3rem .5rem; font-size: .82rem; }
.na { padding: .15rem 0; border-top: 1px solid var(--p-surface-100); }
.na .attenzione { margin-left: .4rem; }
@media (max-width: 900px) {
  .pagina { height: auto; }
  .lavagna { grid-template-columns: 1fr; }
  .elenco { max-height: 24rem; }
  .mappa { height: 55vh; }
}
</style>

<style>
.pa-base span { display: flex; align-items: center; justify-content: center; width: 26px; height: 26px; border-radius: 6px; background: #333; color: #fff; font-weight: 700; font-size: 13px; border: 2px solid #fff; box-shadow: 0 1px 3px rgba(0,0,0,.45); }
.pa-casa span { display: flex; align-items: center; justify-content: center; width: 20px; height: 20px; border-radius: 4px; color: #fff; font-size: 13px; border: 2px solid #fff; box-shadow: 0 1px 3px rgba(0,0,0,.45); }
.pa-tappa span { display: flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 50%; color: #fff; font-weight: 700; font-size: 11px; border: 2px solid #fff; box-shadow: 0 1px 3px rgba(0,0,0,.45); }
</style>
