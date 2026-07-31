<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import Select from 'primevue/select'
import SelectButton from 'primevue/selectbutton'
import Button from 'primevue/button'
import Checkbox from 'primevue/checkbox'
import InputNumber from 'primevue/inputnumber'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// Presenze TeamSystem: dalle presenze di UTENTI_ATTIVITA al file mensile per lo
// studio paghe (tracciato INTM/DIPE/GG01/GG02/PRES). Si sceglie filiale e mese
// (corrente/precedente), si controlla il riepilogo con le anomalie e si scarica
// il CSV. Le ore/giorno sono modificabili per includere lo straordinario stabile
// (che non e' nel gestionale e per la legenda va sommato alle ore ORD).

const toast = useToast()
const errore = ref('')
const filiali = ref([])
const filiale = ref(null)
const mese = ref(null)
const riepilogo = ref(null)
const analisi = ref(false)
const scaricando = ref(false)
const completa = ref(true)
const oreForzate = ref({})        // matricola -> ore/giorno modificate a video

const MESI = ['gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno',
  'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre']
const opzioniMese = (() => {
  const oggi = new Date()
  const corrente = { anno: oggi.getFullYear(), mese: oggi.getMonth() }
  const prec = new Date(oggi.getFullYear(), oggi.getMonth() - 1, 1)
  const fmt = d => `${d.anno}-${String(d.mese + 1).padStart(2, '0')}`
  return [
    { label: `Mese precedente (${MESI[prec.getMonth()]} ${prec.getFullYear()})`,
      value: fmt({ anno: prec.getFullYear(), mese: prec.getMonth() }) },
    { label: `Mese corrente (${MESI[corrente.mese]} ${corrente.anno})`, value: fmt(corrente) }
  ]
})()

onMounted(async () => {
  mese.value = opzioniMese[0].value
  try {
    const { data } = await api.get('/presenze/init')
    filiali.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento delle filiali'
  }
})

async function analizza() {
  analisi.value = true
  riepilogo.value = null
  oreForzate.value = {}
  try {
    const { data } = await api.get('/presenze/riepilogo', {
      params: { idFiliale: filiale.value.idFiliale, mese: mese.value }
    })
    riepilogo.value = data
    for (const d of data.dipendenti) oreForzate.value[d.matricola] = d.oreGiornaliere
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Riepilogo', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  } finally {
    analisi.value = false
  }
}

const conMancanti = computed(() => riepilogo.value?.dipendenti.filter(d => d.mancanti.length) ?? [])
const conAnomalie = computed(() => riepilogo.value?.dipendenti.filter(d => d.anomalie.length) ?? [])

async function scarica() {
  scaricando.value = true
  try {
    const ore = riepilogo.value.dipendenti
      .filter(d => oreForzate.value[d.matricola] != null && oreForzate.value[d.matricola] !== d.oreGiornaliere)
      .map(d => `${d.matricola}=${oreForzate.value[d.matricola]}`)
      .join(',')
    const { data, headers } = await api.get('/presenze/file', {
      params: {
        idFiliale: filiale.value.idFiliale, mese: mese.value,
        completa: completa.value || undefined, ore: ore || undefined
      },
      responseType: 'blob'
    })
    const nome = /filename="?([^";]+)/.exec(headers['content-disposition'] ?? '')?.[1]
      ?? `Presenze_TS_Fil${filiale.value.codiceTs}_${mese.value}.csv`
    const url = URL.createObjectURL(data)
    const a = document.createElement('a')
    a.href = url; a.download = nome; a.click()
    URL.revokeObjectURL(url)
  } catch (e) {
    let msg = 'Errore nella generazione'
    try { msg = JSON.parse(await e.response.data.text()).errore ?? msg } catch { /* risposta non JSON */ }
    toast.add({ severity: 'error', summary: 'File presenze', detail: msg, life: 6000 })
  } finally {
    scaricando.value = false
  }
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">Presenze TeamSystem</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <section class="card">
      <div class="card-titolo">Filiale e mese</div>
      <div class="griglia">
        <label>Filiale *
          <Select v-model="filiale" :options="filiali" optionLabel="filiale" filter fluid
            placeholder="— scegli la filiale —" :loading="!filiali.length && !errore">
            <template #option="{ option }">
              {{ option.filiale }} <small class="muto">— cod. TS {{ option.codiceTs }}</small>
            </template>
          </Select>
        </label>
        <label>Mese *
          <SelectButton v-model="mese" :options="opzioniMese" optionLabel="label" optionValue="value"
            :allowEmpty="false" />
        </label>
        <div class="azione">
          <Button label="Analizza" icon="pi pi-search" :disabled="!filiale || !mese"
            :loading="analisi" @click="analizza" />
        </div>
      </div>
    </section>

    <template v-if="riepilogo">
      <div class="cards">
        <div class="statone"><b>{{ riepilogo.totali.dipendenti }}</b><span>dipendenti</span></div>
        <div class="statone"><b>{{ riepilogo.totali.presenze }}</b><span>giorni di presenza</span></div>
        <div class="statone"><b>{{ riepilogo.totali.assenze }}</b><span>giorni di assenza</span></div>
        <div class="statone" :class="{ ko: riepilogo.totali.mancanti > 0 }">
          <b>{{ riepilogo.totali.mancanti }}</b><span>giorni senza dati</span>
        </div>
      </div>

      <Message v-for="(a, i) in riepilogo.anomalie" :key="i" severity="warn" :closable="false">{{ a }}</Message>
      <Message v-if="!riepilogo.anomalie.length && !conAnomalie.length && !riepilogo.totali.mancanti"
        severity="success" :closable="false">
        Nessuna anomalia: il mese è completo per tutti i dipendenti.
      </Message>

      <section class="card">
        <div class="card-titolo">{{ riepilogo.filiale }} — {{ riepilogo.mese }}
          <span class="conteggio">cod. TS {{ riepilogo.codiceTs ?? '—' }}</span>
        </div>
        <DataTable :value="riepilogo.dipendenti" size="small" stripedRows>
          <Column field="matricola" header="Matricola" style="width: 6.5rem" />
          <Column field="nome" header="Nominativo" />
          <Column header="Ore/giorno" style="width: 8rem">
            <template #body="{ data }">
              <InputNumber v-model="oreForzate[data.matricola]" :min="1" :max="16" :maxFractionDigits="2"
                size="small" inputClass="ore-input" v-tooltip.top="'modifica per includere lo straordinario stabile'" />
              <Tag v-if="oreForzate[data.matricola] !== data.oreGiornaliere" severity="info" value="forzate"
                class="tag-forzate" />
            </template>
          </Column>
          <Column field="presenze" header="Presenze" style="width: 5.5rem" />
          <Column field="ferie" header="Ferie" style="width: 4.5rem" />
          <Column field="infortunio" header="Infort." style="width: 4.5rem" />
          <Column field="malattia" header="Malattia" style="width: 5rem" />
          <Column field="altreAssenze" header="Altre ass." style="width: 5.5rem" />
          <Column field="riposi" header="Riposi" style="width: 4.5rem" />
          <Column header="Senza dati" style="width: 7rem">
            <template #body="{ data }">
              <Tag v-if="data.mancanti.length" severity="warn" :value="String(data.mancanti.length)"
                v-tooltip.left="'giorni: ' + data.mancanti.join(', ')" />
              <span v-else>—</span>
            </template>
          </Column>
          <Column header="Anomalie">
            <template #body="{ data }">
              <div class="anomalie-cella">
                <Tag v-for="(a, i) in data.anomalie" :key="i" severity="danger" :value="a" />
                <span v-if="!data.anomalie.length">—</span>
              </div>
            </template>
          </Column>
        </DataTable>
        <div class="barra-scarica">
          <span class="chk">
            <Checkbox v-model="completa" binary />
            completa i giorni senza dati con l'orario contrattuale (domeniche escluse)
          </span>
          <Button label="Scarica file TeamSystem" icon="pi pi-download"
            :disabled="!riepilogo.codiceTs || !riepilogo.dipendenti.length"
            :loading="scaricando" @click="scarica" />
        </div>
      </section>
    </template>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1250px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center;
}
.conteggio { font-size: .8rem; font-weight: 400; opacity: .9; }
.griglia { display: grid; grid-template-columns: minmax(16rem, 1fr) auto auto; gap: .8rem; padding: .8rem; align-items: end; }
.griglia label { display: flex; flex-direction: column; gap: .25rem; font-size: .85rem; color: #555; }
.azione { display: flex; align-items: flex-end; }
.muto { color: var(--p-text-muted-color); }
.cards { display: grid; grid-template-columns: repeat(4, 1fr); gap: .8rem; }
.statone {
  border: 1px solid var(--p-surface-200); border-radius: 8px; padding: .7rem 1rem;
  display: flex; flex-direction: column; gap: .1rem;
}
.statone b { font-size: 1.5rem; }
.statone span { font-size: .8rem; color: var(--p-text-muted-color); }
.statone.ko b { color: var(--p-orange-600); }
.anomalie-cella { display: flex; flex-wrap: wrap; gap: .25rem; }
:deep(.ore-input) { width: 4.5rem; padding: .25rem .4rem; font-size: .85rem; }
.tag-forzate { margin-left: .35rem; }
.barra-scarica {
  display: flex; justify-content: space-between; align-items: center;
  padding: .7rem .8rem; border-top: 1px solid var(--p-surface-200); gap: 1rem; flex-wrap: wrap;
}
.chk { display: flex; align-items: center; gap: .5rem; font-size: .85rem; color: #555; }
</style>
