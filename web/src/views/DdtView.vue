<script setup>
import { ref, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import { useAuthStore } from '../stores/auth'
import api from '../api'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Textarea from 'primevue/textarea'
import Select from 'primevue/select'
import Dialog from 'primevue/dialog'
import Message from 'primevue/message'
import ProgressSpinner from 'primevue/progressspinner'

// DDT - creazione (videata legacy "Bollainterna"): bolla di trasferimento tra
// filiali. Alla conferma chiama la SP legacy SPED_BOLLA e mostra subito il PDF
// del report DELIVERY_SpedBolla.fr3 (via proxy /api/report).

const auth = useAuthStore()
const toast = useToast()
const errore = ref('')
const lk = ref({ mittenti: [], destinazioni: [], driver: [], mezzi: [], motrici: [], driverMotrici: [] })

function formVuoto() {
  return {
    idFilialeMittente: auth.utente?.idFiliale ?? null,
    idFilialeDestinazione: null,
    note: '',
    motrice: '',
    idDriver: null,
    driverNonSpeedy: null,
    idMezzo: null,
    targaNonSpeedy: null,
    sigillo1: '', sigillo2: '', sigillo3: ''
  }
}
const form = ref(formVuoto())
const salvataggio = ref(false)

onMounted(async () => {
  try {
    const { data } = await api.get('/ddt/lookups')
    lk.value = data
    // mittente: di norma la SP (tipo 11) restituisce solo la filiale corrente
    if (data.mittenti.length === 1) form.value.idFilialeMittente = data.mittenti[0].idfiliale
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle tendine'
  }
})

// --- visore PDF (stesso meccanismo delle interrogazioni: blob dal proxy) ---
const visore = ref({ visibile: false, titolo: '', src: '', caricamento: false })
let blobCorrente = null
function chiudiVisore() {
  visore.value.visibile = false
  if (blobCorrente) { URL.revokeObjectURL(blobCorrente); blobCorrente = null }
}
async function mostraReport(idSpedizione, titolo) {
  visore.value = { visibile: true, titolo, src: '', caricamento: true }
  try {
    const { data } = await api.get('/report', {
      params: { src: `DELIVERY_SpedBolla.fr3|idspedizione=${idSpedizione}` },
      responseType: 'blob'
    })
    if (blobCorrente) URL.revokeObjectURL(blobCorrente)
    blobCorrente = URL.createObjectURL(data)
    visore.value.src = blobCorrente
  } catch (e) {
    chiudiVisore()
    let msg = 'Errore nella generazione del report'
    try { msg = JSON.parse(await e.response?.data?.text())?.errore ?? msg } catch {}
    toast.add({ severity: 'error', summary: 'Stampa DDT', detail: msg, life: 5000 })
  } finally {
    visore.value.caricamento = false
  }
}

async function conferma() {
  if (!form.value.idFilialeMittente || !form.value.idFilialeDestinazione) {
    toast.add({ severity: 'warn', summary: 'Bolla', detail: 'Scegli filiale mittente e destinazione', life: 3000 })
    return
  }
  salvataggio.value = true
  try {
    const f = form.value
    // come il legacy: @Driver testuale = "Driver Non Speedy" + " " + Motrice
    const driverTesto = [f.driverNonSpeedy, f.motrice].map(x => `${x ?? ''}`.trim()).filter(Boolean).join(' ')
    const { data } = await api.post('/ddt', {
      idFilialeMittente: f.idFilialeMittente,
      idFilialeDestinazione: f.idFilialeDestinazione,
      notaConsegna: f.note,
      idDriver: f.idDriver,
      driver: driverTesto || null,
      idMezzo: f.idMezzo,
      targa: f.targaNonSpeedy,
      sigillo1: f.sigillo1 || null,
      sigillo2: f.sigillo2 || null,
      sigillo3: f.sigillo3 || null
    })
    toast.add({ severity: 'success', summary: 'Bolla creata', detail: `Barcode ${data.barcode}`, life: 4000 })
    // come il ReStart del legacy: form pulito, poi il PDF della bolla
    form.value = formVuoto()
    if (lk.value.mittenti.length === 1) form.value.idFilialeMittente = lk.value.mittenti[0].idfiliale
    mostraReport(data.idSpedizione, `DDT ${data.barcode}`)
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Creazione bolla', detail: e.response?.data?.errore ?? 'Errore imprevisto', life: 5000 })
  } finally {
    salvataggio.value = false
  }
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">DDT - creazione</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <div class="scheda">
      <div class="scheda-titolo">Bolla</div>

      <div class="campo">
        <label>Fil. Mitt.</label>
        <Select
          v-model="form.idFilialeMittente" :options="lk.mittenti"
          optionValue="idfiliale" optionLabel="filiale" filter fluid
        />
      </div>
      <div class="campo">
        <label>Filiale</label>
        <Select
          v-model="form.idFilialeDestinazione" :options="lk.destinazioni"
          optionValue="idfiliale" optionLabel="filiale" filter showClear fluid
          placeholder="Filiale di destinazione"
        />
      </div>
      <div class="campo">
        <label>Note</label>
        <Textarea v-model="form.note" rows="4" fluid />
      </div>

      <div class="campo campo-destra">
        <label>Motrice</label>
        <InputText v-model="form.motrice" maxlength="100" fluid />
      </div>
      <div class="campo doppio">
        <label>Driver</label>
        <Select
          v-model="form.idDriver" :options="lk.driver"
          optionValue="IdUtente" optionLabel="Nome" filter showClear fluid
        />
        <label class="etichetta2">Driver Non Speedy</label>
        <Select
          v-model="form.driverNonSpeedy" :options="lk.driverMotrici"
          optionValue="valore" optionLabel="valore" filter showClear fluid
        />
      </div>
      <div class="campo doppio">
        <label>Mezzo</label>
        <Select
          v-model="form.idMezzo" :options="lk.mezzi"
          optionValue="idMezzo" optionLabel="targa" filter showClear fluid
        />
        <label class="etichetta2">Targa non Speedy</label>
        <Select
          v-model="form.targaNonSpeedy" :options="lk.motrici"
          optionValue="valore" optionLabel="valore" filter showClear fluid
        />
      </div>
      <div class="campo">
        <label>Sigillo1</label>
        <InputText v-model="form.sigillo1" maxlength="50" fluid />
      </div>
      <div class="campo">
        <label>Sigillo2</label>
        <InputText v-model="form.sigillo2" maxlength="50" fluid />
      </div>
      <div class="campo">
        <label>Sigillo3</label>
        <InputText v-model="form.sigillo3" maxlength="50" fluid />
      </div>

      <Button
        label="Conferma" class="conferma" :loading="salvataggio" @click="conferma"
      />
    </div>

    <!-- visore PDF della bolla -->
    <Dialog
      :visible="visore.visibile"
      @update:visible="v => { if (!v) chiudiVisore() }"
      modal maximizable
      :header="visore.titolo"
      :style="{ width: '80vw', height: '85vh' }"
      contentClass="visore-contenuto"
    >
      <div v-if="visore.caricamento" class="centro"><ProgressSpinner /></div>
      <iframe v-else-if="visore.src" :src="visore.src" class="visore-frame" />
      <template #footer>
        <Button label="Chiudi" @click="chiudiVisore" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.titolo { margin: 0 0 .75rem; }
.scheda {
  max-width: 820px;
  border: 1px solid var(--p-surface-200);
  border-radius: 6px;
  padding: 1rem 1.25rem;
  display: flex;
  flex-direction: column;
  gap: .75rem;
}
.scheda-titolo { text-align: center; color: #666; font-weight: 600; }
.campo {
  display: grid;
  grid-template-columns: 8rem 1fr;
  align-items: center;
  gap: .5rem;
}
.campo > label { font-size: .9rem; color: #444; }
.campo.doppio { grid-template-columns: 8rem 1fr 9.5rem 1fr; }
.etichetta2 { font-size: .9rem; color: #444; text-align: right; padding-right: .25rem; }
.campo-destra { grid-template-columns: 8rem 1fr; max-width: 60%; margin-left: auto; }
.conferma { margin-top: .5rem; width: 100%; }
.centro { display: flex; justify-content: center; padding: 3rem; }
:global(.visore-contenuto) { height: 100%; display: flex; flex-direction: column; }
.visore-frame { flex: 1; width: 100%; height: 100%; min-height: 60vh; border: 0; }
</style>
