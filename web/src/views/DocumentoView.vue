<script setup>
// Un documento PDF aperto da una voce di menu il cui Link finisce in .pdf (es. la guida "Gestione dei giri" in
// fondo a Gestione Giri Filiale): si legge dentro il portale col visore del browser, e si puo' aprire in una
// scheda a parte o scaricare. I PDF stanno in web/public/doc e vanno in linea con la release.
defineProps({
  url: { type: String, required: true },
  titolo: { type: String, default: 'Documento' },
})
import Button from 'primevue/button'
const nomeFile = u => decodeURIComponent((u || '').split('/').pop() || 'documento.pdf')
</script>

<template>
  <div class="pagina">
    <div class="testata">
      <h2>{{ titolo }}</h2>
      <span class="spazio"></span>
      <a :href="url" target="_blank" rel="noopener">
        <Button label="Apri in una nuova scheda" icon="pi pi-external-link" size="small" outlined />
      </a>
      <a :href="url" :download="nomeFile(url)">
        <Button label="Scarica" icon="pi pi-download" size="small" />
      </a>
    </div>
    <iframe :src="url" class="visore" :title="titolo"></iframe>
  </div>
</template>

<style scoped>
.pagina { display: flex; flex-direction: column; gap: .5rem; height: calc(100vh - 7rem); min-height: 480px; }
.testata { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.testata h2 { margin: 0; }
.spazio { flex: 1; }
.visore { flex: 1; width: 100%; border: 1px solid var(--p-surface-300); border-radius: 6px; background: #fff; }
@media (max-width: 900px) { .pagina { height: calc(100vh - 5rem); } }
</style>
