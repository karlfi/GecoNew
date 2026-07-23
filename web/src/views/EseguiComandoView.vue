<script setup>
import { ref, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import { useNavStore } from '../stores/nav'
import { parseParametriComando } from '../lib/parametri'
import api from '../api'
import Button from 'primevue/button'
import Textarea from 'primevue/textarea'
import DatePicker from 'primevue/datepicker'
import Dialog from 'primevue/dialog'
import Message from 'primevue/message'
import ProgressSpinner from 'primevue/progressspinner'

// Videata legacy "Eseguicomando": esegue un comando (SP/SQL) definito nei
// parametri dell'azione. Due modalita' come l'InDe:
//  - Comando "0": SQL diretto con segnaposto :data / :valore
//  - Comandi 1043/1044: svincolo / reso al mittente (VerificaBarcode + esiti)
// Se il parametro EseguiSubito=1 la conferma parte da sola all'apertura.

const props = defineProps({
  parametri: { type: String, default: '' }
})

const nav = useNavStore()
const toast = useToast()

const p = parseParametriComando(props.parametri)
const comando = ref(p.IdAzione ?? '0')          // "0", "1043", "1044"
const sqlComando = ref(p.Parametri ?? '')        // SQL/EXEC per il comando 0
const barcodes = ref(p.Parametri ?? '')          // elenco barcode per 1043/1044
const tipoData = (p.Tipo ?? '') === 'Data'       // il comando 0 mostra Data invece di Nota
const messaggioIniziale = ref('')
const nome = ref(p.Nome ?? 'Esegui Comando')

const data = ref(new Date())
const nota = ref('')
const esecuzione = ref(false)
const errore = ref('')

onMounted(() => {
  // testo di svincolo/reso mostrato nella Nota, come il legacy
  if (comando.value === '1043') messaggioIniziale.value = 'Sei sicuro di voler effettuare lo svincolo della spedizione?'
  else if (comando.value === '1044') messaggioIniziale.value = 'Sei sicuro di voler effettuare il reso al mittente della spedizione?'
  if (p.EseguiSubito === '1') conferma()
})

// --- visore report (blob dal proxy /api/report) ---
const visore = ref({ visibile: false, titolo: '', src: '', caricamento: false })
let blobCorrente = null
function chiudiVisore() {
  visore.value.visibile = false
  if (blobCorrente) { URL.revokeObjectURL(blobCorrente); blobCorrente = null }
}
async function mostraReport(report, parametri, titolo) {
  visore.value = { visibile: true, titolo, src: '', caricamento: true }
  try {
    const src = parametri ? `${report}|${parametri}` : report
    const { data: pdf } = await api.get('/report', { params: { src }, responseType: 'blob' })
    if (blobCorrente) URL.revokeObjectURL(blobCorrente)
    blobCorrente = URL.createObjectURL(pdf)
    visore.value.src = blobCorrente
  } catch (e) {
    chiudiVisore()
    let msg = 'Errore nella generazione del report'
    try { msg = JSON.parse(await e.response?.data?.text())?.errore ?? msg } catch {}
    toast.add({ severity: 'error', summary: titolo, detail: msg, life: 5000 })
  } finally {
    visore.value.caricamento = false
  }
}

function finito(res) {
  toast.add({ severity: 'success', summary: nome.value, detail: res.messaggio, life: 3000 })
  if (res.report) mostraReport(res.report, res.reportParametri, nome.value)
  else setTimeout(() => nav.indietro(), 300)   // ReStart del legacy
}

async function conferma() {
  esecuzione.value = true
  errore.value = ''
  try {
    let res
    if (comando.value === '0') {
      const body = { sql: sqlComando.value }
      if (tipoData) body.data = data.value?.toISOString?.().slice(0, 10)
      else body.valore = nota.value
      res = (await api.post('/comando/sql', body)).data
    } else {
      res = (await api.post('/comando/esiti', {
        idAzione: Number(comando.value),
        barcodes: barcodes.value,
        nota: nota.value
      })).data
    }
    finito(res)
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore imprevisto'
  } finally {
    esecuzione.value = false
  }
}

function annulla() { nav.indietro() }
</script>

<template>
  <div class="pagina">
    <div class="scheda">
      <h2 class="titolo">{{ nome }}</h2>

      <p v-if="messaggioIniziale" class="messaggio">{{ messaggioIniziale }}</p>
      <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

      <!-- comando 0 tipo Data: campo data; altrimenti Nota -->
      <div v-if="comando === '0' && tipoData" class="campo">
        <label>Data</label>
        <DatePicker v-model="data" dateFormat="dd/mm/yy" showIcon />
      </div>
      <div v-else class="campo">
        <label>Nota</label>
        <Textarea v-model="nota" rows="4" fluid />
      </div>

      <div class="bottoni">
        <Button label="Annulla" severity="secondary" outlined :disabled="esecuzione" @click="annulla" />
        <Button label="Conferma" :loading="esecuzione" @click="conferma" />
      </div>
    </div>

    <Dialog
      :visible="visore.visibile"
      @update:visible="v => { if (!v) chiudiVisore() }"
      modal maximizable :header="visore.titolo"
      :style="{ width: '80vw', height: '85vh' }"
      contentClass="visore-contenuto"
    >
      <div v-if="visore.caricamento" class="centro"><ProgressSpinner /></div>
      <iframe v-else-if="visore.src" :src="visore.src" class="visore-frame" />
      <template #footer><Button label="Chiudi" @click="chiudiVisore" /></template>
    </Dialog>
  </div>
</template>

<style scoped>
.scheda {
  max-width: 620px;
  border: 1px solid var(--p-surface-200);
  border-radius: 6px;
  padding: 1.25rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.titolo { margin: 0; }
.messaggio { margin: 0; font-weight: 600; }
.campo { display: flex; flex-direction: column; gap: .35rem; }
.campo > label { font-size: .9rem; color: #555; }
.bottoni { display: flex; justify-content: space-between; gap: 1rem; margin-top: .5rem; }
.bottoni :deep(button) { min-width: 8rem; }
.centro { display: flex; justify-content: center; padding: 3rem; }
:global(.visore-contenuto) { height: 100%; display: flex; flex-direction: column; }
.visore-frame { flex: 1; width: 100%; height: 100%; min-height: 60vh; border: 0; }
</style>
