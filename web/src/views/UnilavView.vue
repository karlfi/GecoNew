<script setup>
import { ref, computed } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Checkbox from 'primevue/checkbox'
import Select from 'primevue/select'
import DatePicker from 'primevue/datepicker'

// Carica UNILAV: si trascina il PDF della Comunicazione Obbligatoria, il testo
// viene estratto nel browser (pdfjs) e l'API lo scompone nei campi; la griglia
// mostra il confronto con la scheda UTENTI e su conferma applica i campi scelti
// (SP AI_UTENTI_Unilav_Applica, aggiornamento selettivo).
//
// Dalla stessa pagina passano tutti e quattro i modelli (assunzione, proroga,
// trasformazione, cessazione) e gli annullamenti, che cancellano una
// comunicazione gia' inviata: il tipo lo riconosce l'API dal tracciato del PDF
// e cambia solo cosa viene proposto (le date di fine soprattutto).

const toast = useToast()
const errore = ref('')
const caricamento = ref(false)
const applicando = ref(false)
const nomeFile = ref('')
const dati = ref(null)      // risposta di /parse
const selezione = ref({})   // campo -> bool
const scelte = ref({})      // campo -> valore scelto a video (righe con tendina)
const fileInput = ref(null)
const trascina = ref(false)

async function leggiPdf(file) {
  const buf = await file.arrayBuffer()

  // i byte del PDF vanno al server, che ne estrae il tracciato.json incorporato
  // (fonte preferita); da calcolare PRIMA di darli a pdfjs, che trasferisce il buffer
  let pdfBase64 = null
  if (buf.byteLength < 2 * 1024 * 1024) {
    const bytes = new Uint8Array(buf)
    let bin = ''
    for (let i = 0; i < bytes.length; i += 0x8000) {
      bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000))
    }
    pdfBase64 = btoa(bin)
  }

  // ripiego: testo della pagina, righe ricostruite dalla coordinata Y
  const pdfjs = await import('pdfjs-dist')
  const workerUrl = (await import('pdfjs-dist/build/pdf.worker.min.mjs?url')).default
  pdfjs.GlobalWorkerOptions.workerSrc = workerUrl
  const doc = await pdfjs.getDocument({ data: buf }).promise
  let testo = ''
  for (let p = 1; p <= doc.numPages; p++) {
    const page = await doc.getPage(p)
    const tc = await page.getTextContent()
    const righe = new Map()
    for (const it of tc.items) {
      if (!it.str || !it.str.trim()) continue
      const y = Math.round(it.transform[5])
      if (!righe.has(y)) righe.set(y, [])
      righe.get(y).push({ x: it.transform[4], s: it.str })
    }
    for (const [, items] of [...righe.entries()].sort((a, b) => b[0] - a[0])) {
      testo += items.sort((a, b) => a.x - b.x).map(i => i.s).join(' ') + '\n'
    }
  }
  return { testo, pdfBase64 }
}

async function caricaFile(file) {
  if (!file) return
  if (!/\.pdf$/i.test(file.name)) {
    toast.add({ severity: 'warn', summary: 'Formato', detail: 'Serve un PDF', life: 3000 })
    return
  }
  nomeFile.value = file.name
  caricamento.value = true
  errore.value = ''
  dati.value = null
  try {
    const { testo, pdfBase64 } = await leggiPdf(file)
    const { data } = await api.post('/hr/unilav/parse', { testo, pdfBase64 })
    dati.value = data
    const sel = {}
    const sc = {}
    for (const p of data.proposte) {
      // le righe con la tendina (filiale ambigua) restano da scegliere: non le spunto
      sel[p.campo] = !p.opzioni
      if (p.opzioni) sc[p.campo] = null
      // riga con la data scrivibile (annullamento di cessazione): parte dal valore
      // proposto, che puo' essere vuoto se il documento non dice la scadenza
      if (p.editabile === 'data') sc[p.campo] = p.nuovo ? new Date(p.nuovo) : null
    }
    selezione.value = sel
    scelte.value = sc
  } catch (e) {
    errore.value = e.response?.data?.errore ?? `Errore nella lettura del PDF: ${e.message}`
  } finally {
    caricamento.value = false
  }
}

function onFile(e) { caricaFile(e.target.files[0]); e.target.value = '' }
function onDrop(e) { trascina.value = false; caricaFile(e.dataTransfer.files[0]) }

// una riga con tendina conta solo se e' stata scelta una filiale
const daApplicare = computed(() =>
  (dati.value?.proposte ?? []).filter(p =>
    selezione.value[p.campo] && (!p.opzioni || scelte.value[p.campo])))

async function applica() {
  applicando.value = true
  try {
    const valori = {}
    // stringa vuota = azzeramento voluto (la SP ha i flag @Azzera*)
    for (const p of daApplicare.value) {
      valori[p.campo] = p.opzioni ? scelte.value[p.campo]
        : p.editabile === 'data' ? isoData(scelte.value[p.campo])   // vuota = svuota il campo
        : p.nuovo
    }
    // il codice comunicazione porta con se' anche la data di trasmissione
    if (valori.UnilavCodice && dati.value.estratti.UnilavData) {
      const m = dati.value.estratti.UnilavData.match(/(\d{2})\/(\d{2})\/(\d{4})/)
      if (m) valori.UnilavData = `${m[3]}-${m[2]}-${m[1]}`
    }
    const { data } = await api.post('/hr/unilav/applica', {
      idUtente: dati.value.utente.IdUtente,
      valori
    })
    toast.add({ severity: 'success', summary: 'Scheda aggiornata', detail: `${daApplicare.value.length} campi applicati`, life: 3000 })
    // ricarica il confronto rifacendo il parse sullo stesso testo? piu' semplice: azzera le proposte applicate
    dati.value.proposte = dati.value.proposte.filter(p => !selezione.value[p.campo])
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Aggiornamento', detail: e.response?.data?.errore ?? 'Errore imprevisto', life: 5000 })
  } finally {
    applicando.value = false
  }
}

// il server vuole le date come yyyy-MM-dd; vuoto significa "svuota il campo"
function isoData(d) {
  if (!(d instanceof Date) || isNaN(d)) return ''
  const p = n => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

const ETICHETTE_ESTRATTI = [
  ['CodiceFiscale', 'Codice fiscale'], ['Cognome', 'Cognome'], ['Nome', 'Nome'], ['Sesso', 'Sesso'],
  ['DataNascita', 'Nato il'], ['ComuneNascita', 'Luogo di nascita'], ['Cittadinanza', 'Cittadinanza'],
  ['IndirizzoDomicilio', 'Domicilio'], ['CapDomicilio', 'CAP'], ['ComuneDomicilio', 'Comune'],
  ['TitoloStudio', 'Titolo di studio'],
  ['DataInizioRapporto', 'Inizio rapporto'], ['DataFineRapporto', 'Fine prevista'],
  ['DataFineProroga', 'Fine proroga'], ['DataTrasformazione', 'Data trasformazione'],
  ['CausaTrasformazione', 'Causa trasformazione'],
  ['DataCessazione', 'Data cessazione'], ['MotivoCessazione', 'Motivo cessazione'],
  ['CodiceAnnullato', 'Annulla la comunicazione'], ['Note', 'Note'],
  ['TipoContratto', 'Contratto'], ['TipoOrario', 'Orario'], ['OreSettimanali', 'Ore/sett.'],
  ['Qualifica', 'Qualifica'], ['LivelloInquadramento', 'Livello'], ['CCNL', 'CCNL'],
  ['SoggiornoTipo', 'Soggiorno'], ['SoggiornoNumero', 'N. titolo'], ['SoggiornoMotivo', 'Motivo'],
  ['SoggiornoScadenza', 'Scadenza soggiorno'], ['SoggiornoQuestura', 'Questura'],
  ['SedeLavoroComune', 'Sede di lavoro'], ['UnilavCodice', 'Cod. comunicazione'], ['UnilavData', 'Trasmessa il'],
]
const estrattiVisibili = computed(() =>
  ETICHETTE_ESTRATTI.filter(([k]) => dati.value?.estratti?.[k]).map(([k, l]) => ({ etichetta: l, valore: dati.value.estratti[k] })))

const SEVERITA_TIPO = {
  assunzione: 'success', proroga: 'info', trasformazione: 'warn',
  cessazione: 'danger', annullamento: 'contrast'
}
const ICONE_TIPO = {
  assunzione: 'pi pi-user-plus', proroga: 'pi pi-calendar-plus',
  trasformazione: 'pi pi-sync', cessazione: 'pi pi-user-minus',
  annullamento: 'pi pi-undo'
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Carica UNILAV — assunzione, proroga, trasformazione, cessazione, annullamento</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div
      class="dropzone" :class="{ attiva: trascina }"
      @dragover.prevent="trascina = true" @dragleave="trascina = false" @drop.prevent="onDrop"
      @click="fileInput.click()"
    >
      <input ref="fileInput" type="file" accept="application/pdf" hidden @change="onFile" />
      <i class="pi pi-file-pdf" style="font-size: 1.6rem"></i>
      <span v-if="caricamento">Lettura del PDF…</span>
      <span v-else-if="nomeFile">{{ nomeFile }} — clicca o trascina per cambiare file</span>
      <span v-else>Trascina qui il PDF della Comunicazione Obbligatoria, o clicca per sceglierlo</span>
    </div>

    <template v-if="dati">
      <div class="tipo-com">
        <Tag :value="dati.titoloTipo" :severity="SEVERITA_TIPO[dati.tipo] ?? 'info'"
          :icon="ICONE_TIPO[dati.tipo] ?? 'pi pi-file'" class="tag-tipo" />
        <span v-if="dati.causale" class="causale">{{ dati.causale }}</span>
      </div>

      <Message v-for="(a, i) in dati.avvisi" :key="i" severity="warn" :closable="false">{{ a }}</Message>

      <div v-if="dati.utente" class="scheda">
        <b>{{ dati.utente.Nome }}</b>
        <Tag :value="dati.fonte" :severity="dati.fonte.includes('tracciato') ? 'success' : 'secondary'" icon="pi pi-file-import" />
        <Tag :value="'login ' + dati.utente.Utente" severity="secondary" />
        <Tag :value="'matr. ' + (dati.utente.Matricola || '—')" />
        <Tag :value="dati.utente.Filiale" severity="info" />
        <Tag v-if="dati.utente.DataFine" :value="'cessato ' + dati.utente.DataFine" severity="danger" />
        <Tag v-if="dati.altriAccount" :value="dati.altriAccount + ' altri account con questo CF'" severity="warn" />
      </div>

      <template v-if="dati.utente">
        <Message v-if="!dati.proposte.length" severity="success" :closable="false">
          La scheda è già allineata con il PDF: niente da aggiornare.
        </Message>
        <template v-else>
          <div class="barra">
            <span>{{ daApplicare.length }} campi selezionati su {{ dati.proposte.length }} proposti</span>
            <Button label="Applica i campi selezionati" icon="pi pi-check" severity="success"
              :disabled="!daApplicare.length" :loading="applicando" @click="applica" />
          </div>
          <DataTable :value="dati.proposte" size="small" stripedRows>
            <Column style="width: 3rem">
              <template #body="{ data }">
                <Checkbox v-model="selezione[data.campo]" binary />
              </template>
            </Column>
            <Column field="etichetta" header="Campo" style="width: 14rem" />
            <Column field="attuale" header="In scheda ora">
              <template #body="{ data }">
                <span :class="{ vuoto: !data.attuale }">{{ data.attuale || '(vuoto)' }}</span>
              </template>
            </Column>
            <Column field="nuovo" header="Dal PDF">
              <template #body="{ data }">
                <!-- filiale ambigua: si sceglie a video; azzeramento: campo da svuotare -->
                <Select v-if="data.opzioni" v-model="scelte[data.campo]" :options="data.opzioni"
                  optionLabel="etichetta" optionValue="valore" filter size="small"
                  placeholder="scegli la filiale…" class="sel-filiale" />
                <!-- annullamento di cessazione: la fine rapporto la puo' correggere
                     l'operatore, perche' il documento non sempre dice la scadenza -->
                <DatePicker v-else-if="data.editabile === 'data'" v-model="scelte[data.campo]"
                  dateFormat="dd/mm/yy" showIcon showButtonBar size="small"
                  placeholder="nessuna scadenza" class="data-scrivibile" />
                <span v-else-if="data.azzera" class="azzera">
                  <i class="pi pi-eraser"></i> da svuotare
                </span>
                <b v-else>{{ data.campo === 'IdFiliale' ? data.testo : data.nuovo }}</b>
                <small v-if="data.testo && data.campo !== 'IdFiliale'" class="nota-valore">({{ data.testo }})</small>
              </template>
            </Column>
          </DataTable>
        </template>
      </template>

      <details class="estratti">
        <summary>Tutti i dati letti dal PDF ({{ estrattiVisibili.length }})</summary>
        <table>
          <tr v-for="e in estrattiVisibili" :key="e.etichetta">
            <td class="eti">{{ e.etichetta }}</td>
            <td>{{ e.valore }}</td>
          </tr>
        </table>
      </details>
    </template>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.75rem; }
.titolo { margin: 0; }
.dropzone {
  display: flex; align-items: center; gap: 0.75rem; padding: 1.25rem;
  border: 2px dashed var(--p-surface-400); border-radius: 8px;
  cursor: pointer; color: var(--p-text-muted-color);
}
.dropzone.attiva { border-color: var(--p-primary-color); background: var(--p-highlight-background); }
.tipo-com { display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; }
.tag-tipo { font-size: 0.95rem; padding: 0.3rem 0.7rem; }
.causale { color: var(--p-text-muted-color); }
.scheda { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; }
.azzera { color: var(--p-orange-600); font-weight: 600; display: inline-flex; align-items: center; gap: 0.3rem; }
.nota-valore { color: var(--p-text-muted-color); margin-left: 0.4rem; }
.data-scrivibile { width: 13rem; }
.sel-filiale { min-width: 18rem; }
.barra { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
.vuoto { color: var(--p-text-muted-color); font-style: italic; }
.estratti summary { cursor: pointer; color: var(--p-text-muted-color); }
.estratti table { margin-top: 0.5rem; border-collapse: collapse; }
.estratti td { padding: 0.15rem 0.75rem 0.15rem 0; vertical-align: top; }
.estratti .eti { color: var(--p-text-muted-color); white-space: nowrap; }
</style>
