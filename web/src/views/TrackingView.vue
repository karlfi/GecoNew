<script setup>
import { ref, computed } from 'vue'
import api from '../api'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Message from 'primevue/message'
import Dialog from 'primevue/dialog'

// Tracking Barcode: replica della videata legacy. Un barcode -> SP Tracking
// (testata destinatario) + SP RicercaBarcode (movimenti con link ai report).

const barcode = ref('')
const errore = ref('')
const caricamento = ref(false)
const dest = ref(null)        // prima riga della SP Tracking
const movimenti = ref([])

async function cerca() {
  const bc = barcode.value.trim()
  if (!bc) return
  caricamento.value = true
  errore.value = ''
  dest.value = null
  movimenti.value = []
  try {
    const { data } = await api.get('/tracking', { params: { barcode: bc } })
    dest.value = data.destinatario
    movimenti.value = data.movimenti
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nella ricerca del barcode'
  } finally {
    caricamento.value = false
  }
}

// Report PDF: il server dei report risponde solo dalla rete del server, quindi
// il PDF lo scarica l'API (proxy /api/report) e qui si mostra in un frame.
// Va chiesto con axios, che aggiunge il token: aprendo il link direttamente il
// browser non manderebbe le credenziali e riceverebbe un 401.
const pdf = ref({ visibile: false, url: null, caricamento: false })

async function apriReport(link) {
  pdf.value = { visibile: true, url: null, caricamento: true }
  try {
    const { data } = await api.get(link.replace(/^\/api/, ''), { responseType: 'blob' })
    if (pdf.value.url) URL.revokeObjectURL(pdf.value.url)
    pdf.value.url = URL.createObjectURL(data)
  } catch (e) {
    pdf.value.visibile = false
    let msg = 'Errore nella generazione del report'
    try { msg = JSON.parse(await e.response.data.text()).errore ?? msg } catch { /* risposta non JSON */ }
    errore.value = msg
  } finally {
    pdf.value.caricamento = false
  }
}
function chiudiPdf() {
  if (pdf.value.url) URL.revokeObjectURL(pdf.value.url)
  pdf.value = { visibile: false, url: null, caricamento: false }
}

// campi della testata, nell'ordine del legacy: [etichetta, chiave]
const CAMPI = [
  ['Barcode', 'barcode'],
  ['Nome', 'DestinazioneRagioneSociale'],
  ['Indirizzo', 'DestinazioneIndirizzo'],
  ['Comune', 'Comune'],
  ['Prodotto', 'Prodotto'],
  ['Lotto', 'lotto'],
  ['Esito', 'Descrizione'],
  ['Data di accettazione', 'DataCarico'],
  ['Giacenza', 'Giacenza'],
  ['Distribuzione', 'Distribuzione'],
  ['Cliente', 'Cliente'],
  ['Mittente', 'Mittente'],
  ['Note', 'Nota2']
]

// punto da mostrare sulla mappa: coordinate GPS della consegna se la SP le
// restituisce, altrimenti l'indirizzo del destinatario (geocodifica di Google)
const puntoMappa = computed(() => {
  if (!dest.value) return null
  const lat = dest.value.Latitude
  const lng = dest.value.Longitude
  if (lat != null && lng != null && `${lat}`.trim() !== '' && `${lng}`.trim() !== '')
    return `${lat},${lng}`
  const indirizzo = [dest.value.DestinazioneIndirizzo, dest.value.Comune]
    .map(x => `${x ?? ''}`.trim()).filter(Boolean).join(', ')
  return indirizzo ? encodeURIComponent(indirizzo) : null
})

function fmtData(v) {
  if (!v) return ''
  const d = new Date(v)
  if (isNaN(d)) return v
  if (d.getFullYear() <= 1900) return ''       // riga-separatore del legacy
  const data = d.toLocaleDateString('it-IT')
  const ore = d.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })
  return ore === '00:00' ? data : `${data} ${ore}`
}
// riga-separatore ("Dettaglio attivita:"): il legacy la evidenzia in azzurro
function classeRiga(r) {
  const d = new Date(r.data)
  return !isNaN(d) && d.getFullYear() <= 1900 ? 'riga-sezione' : ''
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Tracking Barcode</h2>

    <form class="ricerca" @submit.prevent="cerca">
      <label for="bc">Barcode</label>
      <InputText id="bc" v-model="barcode" autofocus class="campo-bc" />
      <Button type="submit" label="Ricerca" icon="pi pi-search" :loading="caricamento" />
    </form>

    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <template v-if="dest">
      <!-- Destinatario -->
      <div class="pannello">
        <div class="pannello-titolo">Destinatario</div>
        <div class="destinatario">
          <dl class="scheda">
            <template v-for="[etichetta, chiave] in CAMPI" :key="chiave">
              <template v-if="`${dest[chiave] ?? ''}`.trim()">
                <dt>{{ etichetta }}</dt>
                <dd>{{ chiave === 'DataCarico' ? dest[chiave] : dest[chiave] }}</dd>
              </template>
            </template>
          </dl>
          <div v-if="puntoMappa || dest.Foto || dest.FirmaPostino" class="lato">
            <iframe
              v-if="puntoMappa"
              class="mappa"
              :src="`https://maps.google.com/maps?q=${puntoMappa}&z=15&output=embed`"
              loading="lazy"
              referrerpolicy="no-referrer-when-downgrade"
            />
            <div v-if="dest.Foto" class="allegato">
              <a :href="dest.Foto" target="_blank" rel="noopener"><img :src="dest.Foto" alt="Foto consegna" /></a>
              <span>Foto</span>
            </div>
            <div v-if="dest.FirmaPostino" class="allegato">
              <a :href="dest.FirmaPostino" target="_blank" rel="noopener"><img :src="dest.FirmaPostino" alt="Firma" /></a>
              <span>Firma</span>
            </div>
          </div>
        </div>
      </div>

      <!-- Movimenti -->
      <div class="pannello">
        <div class="pannello-titolo">Movimenti</div>
        <DataTable :value="movimenti" size="small" stripedRows :rowClass="classeRiga">
          <Column header="Data" style="width: 9.5rem">
            <template #body="{ data }">{{ fmtData(data.data) }}</template>
          </Column>
          <Column field="elemento" header="Elemento" style="width: 30%" />
          <Column field="valore" header="Valore" />
          <Column header="" style="width: 3.5rem; text-align: center">
            <template #body="{ data }">
              <!-- i report passano dal proxy dell'API e vanno chiesti con il token:
                   un link normale aprirebbe una richiesta senza credenziali (401) -->
              <a
                v-if="data.link?.startsWith('/api/')"
                href="#" title="Apri il report PDF"
                @click.prevent="apriReport(data.link)"
              >
                <i class="pi pi-file-pdf pdf-ico" />
              </a>
              <a
                v-else-if="data.link"
                :href="data.link" target="_blank" rel="noopener"
                :title="data.tipo === 'pdf' ? 'Apri il report PDF' : 'Apri il documento'"
              >
                <i class="pi pi-file-pdf pdf-ico" />
              </a>
            </template>
          </Column>
        </DataTable>
      </div>
    </template>

    <p v-else-if="!errore && !caricamento" class="suggerimento">
      Inserisci un barcode e premi Ricerca per vedere il tracking della spedizione.
    </p>

    <!-- report: PDF servito dal backend, mostrato in un frame interno -->
    <Dialog :visible="pdf.visibile" @update:visible="v => { if (!v) chiudiPdf() }"
      modal maximizable header="Report" :style="{ width: '62rem' }">
      <div v-if="pdf.caricamento" class="pdf-attesa">Generazione in corso…</div>
      <iframe v-else-if="pdf.url" :src="pdf.url" class="pdf-frame" title="Report"></iframe>
    </Dialog>
  </div>
</template>

<style scoped>
.pdf-frame { width: 100%; height: 75vh; border: 0; }
.pdf-attesa { padding: 3rem; text-align: center; color: #666; }
.titolo { margin: 0 0 .75rem; }
.ricerca {
  display: flex;
  align-items: center;
  gap: .75rem;
  margin-bottom: 1rem;
}
.ricerca label { font-size: .9rem; color: #555; }
.campo-bc { width: 320px; max-width: 60vw; }

.pannello {
  border: 1px solid var(--p-surface-200);
  border-radius: 6px;
  overflow: hidden;
  margin-bottom: 1rem;
}
.pannello-titolo {
  background: #00a5cf;
  color: #fff;
  padding: .45rem .75rem;
  font-weight: 600;
  font-size: .9rem;
}
.destinatario { display: flex; gap: 1.25rem; padding: .75rem 1rem; }
.scheda {
  flex: 1;
  min-width: 0;
  display: grid;
  grid-template-columns: 11rem 1fr;
  gap: .35rem .75rem;
  margin: 0;
}
.scheda dt { color: #666; font-size: .85rem; }
.scheda dd {
  margin: 0;
  font-size: .9rem;
  border-bottom: 1px solid var(--p-surface-200);
  padding-bottom: .2rem;
  overflow-wrap: anywhere;
}
.lato { flex: 0 0 380px; display: flex; flex-direction: column; gap: .75rem; }
.mappa { width: 100%; height: 280px; border: 0; border-radius: 6px; }
.allegato { text-align: center; font-size: .8rem; color: #666; }
.allegato img { max-width: 100%; max-height: 200px; border: 1px solid var(--p-surface-200); border-radius: 6px; }

.pdf-ico { color: #d32f2f; font-size: 1.15rem; }
:deep(.riga-sezione) { background: #cfe8f7 !important; font-weight: 600; }
.suggerimento { color: #888; font-size: .9rem; }
</style>
