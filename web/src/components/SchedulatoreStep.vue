<script setup>
// Editor di uno step: nome, tipo, i tre flag e i parametri. I parametri sono
// JSON libero: i valori semplici si modificano riga per riga, le liste di
// oggetti (campiFissi e le altre sottostrutture del file step) come griglia,
// il resto come JSON grezzo.
import { ref, watch } from 'vue'
import { useToast } from 'primevue/usetoast'
import api from '../api'
import InputText from 'primevue/inputtext'
import Select from 'primevue/select'
import Checkbox from 'primevue/checkbox'
import Button from 'primevue/button'
import Textarea from 'primevue/textarea'
import { messaggioErrore } from '../lib/schedulatore'

const props = defineProps({ step: Object, tipi: { type: Array, default: () => [] } })
const emit = defineEmits(['salvato', 'elimina', 'sposta', 'aggiungiSotto'])
const toast = useToast()

const nomeSezione = ref('')
const tipo = ref('')
const attivo = ref(true)
const eseguiPasso = ref(true)
const esciSuErrore = ref(false)
const semplici = ref([])
const griglie = ref([])
const grezzi = ref([])
const salvataggio = ref(false)

const eOggetto = v => v !== null && typeof v === 'object' && !Array.isArray(v)

watch(() => props.step, s => {
  semplici.value = []; griglie.value = []; grezzi.value = []
  if (!s) return
  nomeSezione.value = s.NomeSezione
  tipo.value = s.Tipo
  attivo.value = !!s.Attivo
  eseguiPasso.value = !!s.EseguiPasso
  esciSuErrore.value = !!s.EsciSuErrore
  const par = eOggetto(s.Parametri) ? s.Parametri : {}
  for (const [k, v] of Object.entries(par)) {
    if (Array.isArray(v) && v.length && v.every(eOggetto)) {
      const colonne = [...new Set(v.flatMap(o => Object.keys(o)))]
      griglie.value.push({ chiave: k, colonne, righe: v.map(o => Object.fromEntries(colonne.map(c => [c, o[c] == null ? '' : String(o[c])]))) })
    } else if (v === null || typeof v === 'object') {
      grezzi.value.push({ chiave: k, json: JSON.stringify(v, null, 2) })
    } else {
      semplici.value.push({ chiave: k, valore: String(v) })
    }
  }
}, { immediate: true })

// il tipo corrente si vede anche se non e' (piu') tra quelli attivi
const opzioniTipo = () => props.tipi.some(t => t.Codice === tipo.value) ? props.tipi : [{ Codice: tipo.value, Descrizione: '' }, ...props.tipi]
const descrizioneTipo = () => props.tipi.find(t => t.Codice === tipo.value)?.Descrizione

async function salva() {
  if (!props.step) return
  salvataggio.value = true
  try {
    const parametri = {}
    for (const r of semplici.value) if (r.chiave) parametri[r.chiave] = r.valore
    for (const g of griglie.value) parametri[g.chiave] = g.righe
    for (const b of grezzi.value) parametri[b.chiave] = JSON.parse(b.json)   // JSON non valido: finisce nel catch
    await api.put(`/schedulatore/step/${props.step.IdStep}`, {
      parametri, attivo: attivo.value, eseguiPasso: eseguiPasso.value, esciSuErrore: esciSuErrore.value,
      tipo: tipo.value, nomeSezione: nomeSezione.value
    })
    toast.add({ severity: 'success', summary: 'Step salvato', life: 2000 })
    emit('salvato')
  } catch (e) {
    toast.add({ severity: 'error', summary: 'Salvataggio fallito',
      detail: e instanceof SyntaxError ? `JSON non valido: ${e.message}` : messaggioErrore(e), life: 6000 })
  } finally {
    salvataggio.value = false
  }
}
</script>

<template>
  <div v-if="!step" class="vuoto">Seleziona uno step nell'albero per modificarlo.</div>
  <div v-else class="editor">
    <div class="testa">
      <InputText v-model="nomeSezione" class="nome" placeholder="Nome sezione" />
      <Select v-model="tipo" :options="opzioniTipo()" optionLabel="Codice" optionValue="Codice" class="tipo" />
    </div>
    <div class="barra">
      <Button icon="pi pi-arrow-up" text size="small" title="Sposta su" @click="emit('sposta', 'su')" />
      <Button icon="pi pi-arrow-down" text size="small" title="Sposta giù" @click="emit('sposta', 'giu')" />
      <Button label="Sottopasso" icon="pi pi-plus" text size="small" @click="emit('aggiungiSotto')" />
      <Button label="Elimina" icon="pi pi-trash" text size="small" severity="danger" @click="emit('elimina')" />
      <span class="spazio"></span>
      <label><Checkbox v-model="attivo" binary /> Attivo</label>
      <label><Checkbox v-model="eseguiPasso" binary /> Esegui passo</label>
      <label><Checkbox v-model="esciSuErrore" binary /> Esci su errore</label>
    </div>
    <p v-if="descrizioneTipo()" class="descr">{{ descrizioneTipo() }}</p>

    <h4>Parametri</h4>
    <div v-for="(r, i) in semplici" :key="'s' + i" class="riga">
      <InputText v-model="r.chiave" class="chiave" placeholder="nome" size="small" />
      <InputText v-model="r.valore" class="valore" placeholder="valore" size="small" />
      <Button icon="pi pi-times" text size="small" severity="secondary" @click="semplici.splice(i, 1)" />
    </div>
    <div><Button label="Parametro" icon="pi pi-plus" text size="small" @click="semplici.push({ chiave: '', valore: '' })" /></div>

    <template v-for="g in griglie" :key="'g' + g.chiave">
      <h4>{{ g.chiave }} <small>({{ g.righe.length }})</small></h4>
      <div class="scorri">
        <table class="griglia">
          <thead><tr><th v-for="c in g.colonne" :key="c">{{ c }}</th><th></th></tr></thead>
          <tbody>
            <tr v-for="(riga, ri) in g.righe" :key="ri">
              <td v-for="c in g.colonne" :key="c"><input v-model="riga[c]" /></td>
              <td><Button icon="pi pi-times" text size="small" severity="secondary" @click="g.righe.splice(ri, 1)" /></td>
            </tr>
          </tbody>
        </table>
      </div>
      <div><Button label="Riga" icon="pi pi-plus" text size="small" @click="g.righe.push(Object.fromEntries(g.colonne.map(c => [c, ''])))" /></div>
    </template>

    <template v-for="b in grezzi" :key="'b' + b.chiave">
      <h4>{{ b.chiave }} <small>(JSON)</small></h4>
      <Textarea v-model="b.json" rows="5" autoResize class="json" />
    </template>

    <div class="azioni">
      <Button label="Salva step" icon="pi pi-check" :loading="salvataggio" @click="salva" />
    </div>
  </div>
</template>

<style scoped>
.vuoto { color: var(--p-text-muted-color); padding: 1rem; }
.editor { display: flex; flex-direction: column; gap: .5rem; }
.testa { display: flex; gap: .5rem; }
.nome { flex: 1; font-weight: 600; }
.tipo { width: 16rem; }
.barra { display: flex; align-items: center; gap: .25rem; flex-wrap: wrap; }
.barra label { display: flex; align-items: center; gap: .3rem; margin-left: .75rem; font-size: .9rem; }
.spazio { flex: 1; }
.descr { margin: 0; color: var(--p-text-muted-color); font-size: .85rem; }
h4 { margin: .6rem 0 .2rem; }
h4 small { color: var(--p-text-muted-color); font-weight: normal; }
.riga { display: flex; gap: .4rem; align-items: center; }
.chiave { width: 14rem; font-family: monospace; }
.valore { flex: 1; font-family: monospace; }
.scorri { overflow-x: auto; }
.griglia { border-collapse: collapse; font-size: .82rem; }
.griglia th { text-align: left; padding: .2rem .4rem; color: var(--p-text-muted-color); font-weight: 600; white-space: nowrap; }
.griglia td { padding: .1rem .2rem; }
.griglia input { width: 9rem; font-family: monospace; font-size: .82rem; padding: .2rem .3rem;
  border: 1px solid var(--p-content-border-color); border-radius: 4px; background: transparent; color: inherit; }
.json { font-family: monospace; font-size: .82rem; width: 100%; }
.azioni { display: flex; justify-content: flex-end; margin-top: .5rem; }
</style>
