import { defineStore } from 'pinia'

// Navigazione interna senza URL: la barra degli indirizzi resta sempre sulla home,
// come nel legacy. Lo stack permette i drill-down dal tasto destro e il ritorno.
// Pagine: { tipo: 'dashboard' } | { tipo: 'interrogazioni', idQuery, sWhere }
//         | { tipo: 'videata', videata, parametri }
export const useNavStore = defineStore('nav', {
  state: () => ({
    stack: [{ tipo: 'dashboard' }],
    idMenuAttivo: '',
    versione: 0 // incrementata per forzare il ricaricamento della pagina corrente
  }),
  getters: {
    corrente: s => s.stack[s.stack.length - 1],
    puoTornare: s => s.stack.length > 1
  },
  actions: {
    vaiHome() {
      this.stack = [{ tipo: 'dashboard' }]
      this.idMenuAttivo = ''
    },
    apriDaMenu(pagina, idMenu = '') {
      this.stack = [pagina]
      this.idMenuAttivo = String(idMenu)
    },
    drill(pagina) {
      this.stack.push(pagina)
    },
    indietro() {
      if (this.stack.length > 1) this.stack.pop()
    },
    ricarica() {
      this.versione++
    }
  }
})
