<script setup>
// La maschera della ricorrenza, stile "Utilità di pianificazione" di Windows:
// giornaliera / settimanale / mensile con ora di inizio e, a scelta, la
// ripetizione nella giornata; "avanzata" per scrivere il cron a mano.
// Mentre si compila si vede l'espressione, la frase in italiano e le prossime
// tre esecuzioni calcolate dal server.
import { ref, computed, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import RadioButton from 'primevue/radiobutton'
import Checkbox from 'primevue/checkbox'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import InputMask from 'primevue/inputmask'
import Select from 'primevue/select'
import MultiSelect from 'primevue/multiselect'
import api from '../api'
import { GIORNI, MESI, GIORNI_MESE, modelloVuoto, componi, scomponi, descrivi } from '../lib/cron'
import { dataOra } from '../lib/schedulatore'

const props = defineProps({ visible: Boolean, expr: { type: String, default: '' } })
const emit = defineEmits(['update:visible', 'ok'])

const m = ref(modelloVuoto())
const MODI = [
  { valore: 'giornaliera', nome: 'Giornaliera' }, { valore: 'settimanale', nome: 'Settimanale' },
  { valore: 'mensile', nome: 'Mensile' }, { valore: 'avanzata', nome: 'Avanzata (cron a mano)' }
]
const UNITA = [{ valore: 'minuti', nome: 'minuti' }, { valore: 'ore', nome: 'ore' }]
const mesiOpzioni = MESI.map((nome, i) => ({ valore: i + 1, nome }))

// all'apertura: l'espressione che c'era, se la maschera la sa leggere; altrimenti "avanzata"
watch(() => props.visible, v => {
  if (!v) return
  const letto = props.expr ? scomponi(props.expr) : null
  m.value = letto ?? { ...modelloVuoto(), modo: props.expr ? 'avanzata' : 'giornaliera', espressione: props.expr || '' }
}, { immediate: true })

const espressione = computed(() => { try { return { expr: componi(m.value), errore: null } } catch (e) { return { expr: null, errore: e.message } } })
const frase = computed(() => espressione.value.expr ? descrivi(espressione.value.expr) : '')

// le prossime esecuzioni le calcola il server (stessa libreria del motore)
const prossime = ref(null)
let timer = null
watch(espressione, e => {
  clearTimeout(timer)
  prossime.value = null
  if (!e.expr) return
  timer = setTimeout(async () => {
    try { prossime.value = (await api.get('/schedulatore/cron', { params: { expr: e.expr, n: 3 } })).data } catch { prossime.value = null }
  }, 300)
}, { immediate: true })

const valida = computed(() => !!espressione.value.expr && (prossime.value == null || prossime.value.valida))
const chiudi = () => emit('update:visible', false)
const conferma = () => { if (valida.value) { emit('ok', espressione.value.expr); chiudi() } }
</script>

<template>
  <Dialog :visible="visible" @update:visible="chiudi" modal header="Ricorrenza" :style="{ width: '46rem' }">
    <div class="corpo">
      <div class="modi">
        <label v-for="o in MODI" :key="o.valore" class="radio"><RadioButton v-model="m.modo" :value="o.valore" /> {{ o.nome }}</label>
      </div>

      <div class="impostazioni">
        <template v-if="m.modo !== 'avanzata'">
          <label class="riga">Ora di inizio <InputMask v-model="m.ora" mask="99:99" placeholder="hh:mm" class="ora" /></label>

          <div v-if="m.modo === 'settimanale'" class="gruppo">
            <span class="etichetta">Nei giorni</span>
            <div class="giorni">
              <label v-for="g in GIORNI" :key="g.valore" class="check"><Checkbox v-model="m.giorniSettimana" :value="g.valore" /> {{ g.nome }}</label>
            </div>
            <div class="scorciatoie">
              <Button label="lun–ven" link size="small" @click="m.giorniSettimana = [1, 2, 3, 4, 5]" />
              <Button label="tutti" link size="small" @click="m.giorniSettimana = [1, 2, 3, 4, 5, 6, 0]" />
            </div>
          </div>

          <div v-if="m.modo === 'mensile'" class="gruppo">
            <label class="riga">Nei giorni <MultiSelect v-model="m.giorniMese" :options="GIORNI_MESE" optionLabel="nome" optionValue="valore" placeholder="giorni del mese" :maxSelectedLabels="8" class="largo" /></label>
            <label class="riga">Nei mesi <MultiSelect v-model="m.mesi" :options="mesiOpzioni" optionLabel="nome" optionValue="valore" placeholder="tutti i mesi" :maxSelectedLabels="12" class="largo" showClear /></label>
          </div>

          <div class="gruppo ripeti">
            <label class="check"><Checkbox v-model="m.ripeti.attiva" binary /> Ripeti nella giornata</label>
            <div class="riga-ripeti" :class="{ spenta: !m.ripeti.attiva }">
              ogni <InputNumber v-model="m.ripeti.ogni" :min="1" :max="59" :disabled="!m.ripeti.attiva" inputStyle="width: 4.5rem" />
              <Select v-model="m.ripeti.unita" :options="UNITA" optionLabel="nome" optionValue="valore" :disabled="!m.ripeti.attiva" style="width: 8rem" />
              dalle <InputMask v-model="m.ripeti.dalle" mask="99:99" :disabled="!m.ripeti.attiva" class="ora" />
              alle <InputMask v-model="m.ripeti.alle" mask="99:99" :disabled="!m.ripeti.attiva" class="ora" />
            </div>
            <small class="nota">Con i minuti conta la fascia di ore intere (dalle 08 alle 18 = fino alle 18:59); con le ore si parte dai minuti dell'ora "dalle".</small>
          </div>
        </template>

        <label v-else class="riga">Espressione <InputText v-model="m.espressione" placeholder="min ora giorno mese giorno-settimana — es. 0 6 * * 1-5" class="largo mono" /></label>
      </div>

      <div class="anteprima" :class="{ errore: espressione.errore || (prossime && !prossime.valida) }">
        <template v-if="espressione.expr">
          <div><b>{{ frase }}</b> <code>{{ espressione.expr }}</code></div>
          <div v-if="prossime?.valida" class="nota">prossime: {{ prossime.prossime.map(dataOra).join(' · ') }}</div>
          <div v-else-if="prossime" class="nota">{{ prossime.errore }}</div>
        </template>
        <span v-else>{{ espressione.errore }}</span>
      </div>
    </div>
    <template #footer>
      <Button label="Annulla" text @click="chiudi" />
      <Button label="OK" icon="pi pi-check" :disabled="!valida" @click="conferma" />
    </template>
  </Dialog>
</template>

<style scoped>
.corpo { display: flex; flex-direction: column; gap: .9rem; }
.modi { display: flex; gap: 1.2rem; flex-wrap: wrap; }
.radio, .check { display: inline-flex; align-items: center; gap: .4rem; cursor: pointer; }
.impostazioni { display: flex; flex-direction: column; gap: .8rem; padding: .8rem 1rem; border: 1px solid var(--p-content-border-color); border-radius: 8px; }
.gruppo { display: flex; flex-direction: column; gap: .5rem; }
.etichetta { font-size: .85rem; color: var(--p-text-muted-color); }
.riga { display: grid; grid-template-columns: 8rem 1fr; align-items: center; gap: .5rem; font-size: .9rem; color: var(--p-text-muted-color); }
.giorni { display: grid; grid-template-columns: repeat(4, 1fr); gap: .4rem .8rem; }
.scorciatoie { display: flex; gap: .3rem; }
.riga-ripeti { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; padding-left: 1.8rem; }
.riga-ripeti.spenta { color: var(--p-text-muted-color); }
.ora { width: 5.5rem; font-family: monospace; }
.largo { width: 100%; }
.mono { font-family: monospace; }
.anteprima { padding: .6rem .8rem; border-radius: 8px; background: var(--p-content-hover-background); }
.anteprima code { margin-left: .5rem; }
.anteprima.errore { color: var(--p-red-600); }
.nota { color: var(--p-text-muted-color); font-size: .85rem; }
</style>
