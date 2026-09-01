<script setup>
import { ref, computed, onMounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import { frecceRowEdit } from '../lib/frecceGriglia'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import Message from 'primevue/message'
import Tag from 'primevue/tag'
import Checkbox from 'primevue/checkbox'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'

// VideoCodifica: replica della videata legacy "Videocodifica". I lotti caricati da
// file restano "da videocodificare" finche' un operatore non ne corregge le righe
// (barcode e destinatari) e chiude il lotto: la chiusura richiama la stored legacy
// Lotto_VideoCodifica, che genera i barcode mancanti, applica tutte le validazioni
// e marca DataVideoCodifica (da li' il lotto passa al Checkin).

const props = defineProps({ parametri: { type: String, default: '' } })
// filtri estratti con regex direttamente dai Parametri della voce: il legacy li
// scrive sia come coppie (CodFamiglia="N") sia annidati in sWhere="CodFamiglia='N'
// and IdProdotto=78", con maiuscole/minuscole alternate
const codFamigliaParam = (/CodFamiglia\s*=\s*["']*([A-Za-z0-9]+)/i.exec(props.parametri)?.[1] ?? '').trim()
const idClienteParam = parseInt(/IdCliente\s*=\s*["']*(\d+)/i.exec(props.parametri)?.[1], 10) || null
const idProdottoParam = parseInt(/IdProdotto\s*=\s*["']*(\d+)/i.exec(props.parametri)?.[1], 10) || null

const toast = useToast()
const errore = ref('')
const lotti = ref([])
const caricamento = ref(false)
const tutteFiliali = ref(false)

const lotto = ref(null)           // testata del lotto aperto
const righe = ref([])
const righeInEdit = ref([])
const soloDaSistemare = ref(false)
const chiusuraInCorso = ref(false)
const erroreChiusura = ref('')

async function caricaLotti() {
  caricamento.value = true
  try {
    const { data } = await api.get('/videocodifica/lotti', {
      params: {
        tutte: tutteFiliali.value || undefined, codFamiglia: codFamigliaParam || undefined,
        idCliente: idClienteParam || undefined, idProdotto: idProdottoParam || undefined,
        // i lotti da banco del cliente (es. MGG) hanno gia' DataCarico valorizzata
        conCarico: idClienteParam ? true : undefined
      }
    })
    lotti.value = data
  } catch (e) {
    errore.value = e.response?.data?.errore ?? 'Errore nel caricamento dei lotti'
  } finally {
    caricamento.value = false
  }
}
onMounted(caricaLotti)

async function apriLotto(l) {
  errore.value = ''; erroreChiusura.value = ''
  try {
    const { data } = await api.get(`/videocodifica/lotto/${l.IdLotto}`)
    lotto.value = data.testata
    righe.value = data.righe
    righeInEdit.value = []
    soloDaSistemare.value = false
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Lotto', detail: e.response?.data?.errore ?? 'Errore', life: 4000 })
  }
}
function chiudiLotto() {
  lotto.value = null; righe.value = []; erroreChiusura.value = ''
}

// regole di validita' della stored legacy Lotto_VideoCodifica (escl. prodotto 69)
const problemi = r => ({
  barcode: !(r.Barcode ?? '').trim(),
  destinatario: ((r.Destinatario ?? '').trim().length) <= 2,
  indirizzo: ((r.Indirizzo ?? '').trim().length) <= 5,
  localita: ((r.Localita ?? '').trim().length) <= 3,
  cap: ((r.Cap ?? '').trim().length) !== 5,
  prov: ((r.Prov ?? '').trim().length) !== 2
})
// il barcode mancante non blocca: lo genera la stored alla chiusura
const daSistemare = r => { const p = problemi(r); return p.destinatario || p.indirizzo || p.localita || p.cap || p.prov }
const righeVisibili = computed(() => soloDaSistemare.value ? righe.value.filter(daSistemare) : righe.value)
const nDaSistemare = computed(() => righe.value.filter(daSistemare).length)
const nSenzaBarcode = computed(() => righe.value.filter(r => !(r.Barcode ?? '').trim()).length)

async function salvaRiga(ev) {
  const r = ev.newData
  try {
    await api.post('/videocodifica/riga', {
      idSpedizione: r.IdSpedizione, barcode: r.Barcode, destinatario: r.Destinatario,
      indirizzo: r.Indirizzo, civico: r.Civico, localita: r.Localita, cap: r.Cap, prov: r.Prov
    })
    const i = righe.value.findIndex(x => x.IdSpedizione === r.IdSpedizione)
    if (i >= 0) righe.value[i] = { ...r }
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Salvataggio', detail: e.response?.data?.errore ?? 'Errore', life: 5000 })
  }
}

async function chiudiVideocodifica() {
  chiusuraInCorso.value = true
  erroreChiusura.value = ''
  try {
    await api.post('/videocodifica/chiudi', { idLotto: lotto.value.IdLotto })
    toast.add({ severity: 'success', summary: 'VideoCodifica', detail: `Lotto ${lotto.value.Lotto} videocodificato`, life: 5000 })
    chiudiLotto()
    caricaLotti()
  } catch (e) {
    erroreChiusura.value = e.response?.data?.errore ?? 'Errore nella chiusura'
  } finally {
    chiusuraInCorso.value = false
  }
}
</script>

<template>
  <div class="pagina">
    <h2 class="titolo">VideoCodifica{{ codFamigliaParam ? ` — famiglia ${codFamigliaParam}` : '' }}</h2>
    <Message v-if="errore" severity="error" :closable="false">{{ errore }}</Message>

    <!-- elenco dei lotti da videocodificare -->
    <section v-if="!lotto" class="card">
      <div class="card-titolo">Lotti da videocodificare
        <span class="chk-testata"><Checkbox v-model="tutteFiliali" binary @change="caricaLotti" /> tutte le filiali</span>
      </div>
      <DataTable :value="lotti" size="small" stripedRows :loading="caricamento" :rowHover="true"
        paginator :rows="15" @row-click="e => apriLotto(e.data)" class="tab-lotti">
        <Column field="IdLotto" header="Id" style="width: 5.5rem" />
        <Column field="Lotto" header="Lotto" />
        <Column field="Cliente" header="Cliente" />
        <Column field="CodFamiglia" header="Fam." style="width: 3.5rem" />
        <Column field="Prodotto" header="Prodotto" />
        <Column field="Righe" header="Righe" style="width: 4.5rem" />
        <Column header="Senza barcode" style="width: 7.5rem">
          <template #body="{ data }">
            <Tag v-if="data.SenzaBarcode > 0" severity="warn" :value="String(data.SenzaBarcode)" />
            <span v-else>—</span>
          </template>
        </Column>
        <Column field="Filiale" header="Filiale" />
        <Column field="DataInserimento" header="Inserito" style="width: 8.5rem" />
        <template #empty>Nessun lotto in attesa di videocodifica.</template>
      </DataTable>
    </section>

    <!-- dettaglio del lotto: righe editabili -->
    <template v-else>
      <section class="card">
        <div class="card-titolo">
          <span>Lotto {{ lotto.Lotto }} ({{ lotto.IdLotto }}) — {{ lotto.Cliente }} · {{ lotto.Prodotto }}</span>
          <span class="testata-destra">
            <Tag v-if="nSenzaBarcode" severity="warn" :value="`${nSenzaBarcode} senza barcode (generati alla chiusura)`" />
            <Tag v-if="nDaSistemare" severity="danger" :value="`${nDaSistemare} da sistemare`" />
            <Tag v-else severity="success" value="righe complete" />
          </span>
        </div>
        <div class="corpo">
          <div class="barra">
            <Button label="Torna all'elenco" icon="pi pi-arrow-left" text @click="chiudiLotto" />
            <span class="chk"><Checkbox v-model="soloDaSistemare" binary /> solo righe da sistemare</span>
            <span class="spazio"></span>
            <Button label="Chiudi videocodifica" icon="pi pi-check" :loading="chiusuraInCorso"
              @click="chiudiVideocodifica" />
          </div>
          <Message v-if="erroreChiusura" severity="error" :closable="false">{{ erroreChiusura }}</Message>

          <DataTable :value="righeVisibili" size="small" stripedRows dataKey="IdSpedizione"
            editMode="row" v-model:editingRows="righeInEdit" @row-edit-save="salvaRiga"
            @keydown.capture="frecceRowEdit"
            paginator :rows="25" class="tab-righe">
            <Column field="IdSpedizione" header="Id" style="width: 6rem" />
            <Column field="Barcode" header="Barcode" style="width: 13rem">
              <template #body="{ data }">
                <span v-if="data.Barcode">{{ data.Barcode }}</span>
                <Tag v-else severity="warn" value="da generare" />
              </template>
              <template #editor="{ data }"><InputText v-model.trim="data.Barcode" fluid /></template>
            </Column>
            <Column field="Destinatario" header="Destinatario">
              <template #body="{ data }">
                <span :class="{ campoko: problemi(data).destinatario }">{{ data.Destinatario || '—' }}</span>
              </template>
              <template #editor="{ data }"><InputText v-model="data.Destinatario" fluid /></template>
            </Column>
            <Column field="Indirizzo" header="Indirizzo">
              <template #body="{ data }">
                <span :class="{ campoko: problemi(data).indirizzo }">{{ data.Indirizzo || '—' }}</span>
              </template>
              <template #editor="{ data }"><InputText v-model="data.Indirizzo" fluid /></template>
            </Column>
            <Column field="Civico" header="Civico" style="width: 5rem">
              <template #editor="{ data }"><InputText v-model.trim="data.Civico" fluid /></template>
            </Column>
            <Column field="Localita" header="Località" style="width: 11rem">
              <template #body="{ data }">
                <span :class="{ campoko: problemi(data).localita }">{{ data.Localita || '—' }}</span>
              </template>
              <template #editor="{ data }"><InputText v-model="data.Localita" fluid /></template>
            </Column>
            <Column field="Cap" header="CAP" style="width: 5.5rem">
              <template #body="{ data }">
                <span :class="{ campoko: problemi(data).cap }">{{ data.Cap || '—' }}</span>
              </template>
              <template #editor="{ data }"><InputText v-model.trim="data.Cap" maxlength="5" fluid /></template>
            </Column>
            <Column field="Prov" header="Prov" style="width: 4.5rem">
              <template #body="{ data }">
                <span :class="{ campoko: problemi(data).prov }">{{ data.Prov || '—' }}</span>
              </template>
              <template #editor="{ data }">
                <InputText :modelValue="data.Prov" maxlength="2" fluid
                  @update:modelValue="v => data.Prov = (v ?? '').toUpperCase()" />
              </template>
            </Column>
            <Column :rowEditor="true" style="width: 6rem" bodyStyle="text-align:center" />
            <template #empty>Nessuna riga.</template>
          </DataTable>
        </div>
      </section>
    </template>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: 0.9rem; max-width: 1400px; }
.titolo { margin: 0; }
.card { border: 1px solid var(--p-surface-200); border-radius: 8px; }
.card-titolo {
  background: #00a5cf; color: #fff; padding: .45rem .8rem; font-weight: 600;
  border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center; gap: .8rem;
}
.chk-testata { display: flex; align-items: center; gap: .4rem; font-size: .82rem; font-weight: 400; }
.testata-destra { display: flex; gap: .5rem; font-weight: 400; }
.corpo { padding: .8rem; display: flex; flex-direction: column; gap: .8rem; }
.barra { display: flex; align-items: center; gap: 1rem; }
.barra .spazio { flex: 1; }
.chk { display: flex; align-items: center; gap: .4rem; font-size: .85rem; color: #555; }
.tab-lotti :deep(.p-datatable-tbody > tr) { cursor: pointer; }
.campoko { color: var(--p-red-600); font-weight: 600; }
</style>
