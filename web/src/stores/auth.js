import { defineStore } from 'pinia'
import api from '../api'

export const useAuthStore = defineStore('auth', {
  state: () => ({
    token: localStorage.getItem('token'),
    utente: JSON.parse(localStorage.getItem('utente') ?? 'null'),
    menu: [],
    menuErrore: '',
    filiali: []
  }),
  getters: {
    autenticato: s => !!s.token
  },
  actions: {
    async login(utente, password) {
      const { data } = await api.post('/auth/login', { utente, password })
      this.salvaAccesso(data)
    },
    // solo in sviluppo (npm run dev): entra con l'utente di prova di api/appsettings.Development.json
    async accessoSviluppo() {
      const { data } = await api.post('/auth/dev-login')
      this.salvaAccesso(data)
    },
    salvaAccesso(data) {
      this.token = data.token
      this.utente = data.utente
      localStorage.setItem('token', data.token)
      localStorage.setItem('utente', JSON.stringify(data.utente))
    },
    async caricaMenu() {
      this.menuErrore = ''
      try {
        const { data } = await api.get('/me/menu')
        this.menu = data
      } catch (e) {
        this.menuErrore = e.response?.data?.errore ?? 'Errore nel caricamento del menu'
      }
    },
    async caricaFiliali() {
      try {
        const { data } = await api.get('/me/filiali')
        this.filiali = data
      } catch {
        this.filiali = []
      }
    },
    async cambiaFiliale(idFiliale) {
      const { data } = await api.post('/me/filiale', { idFiliale })
      this.token = data.token
      this.utente = {
        ...this.utente,
        idFiliale: data.idFiliale,
        idAzienda: data.idAzienda,
        filiale: data.filiale
      }
      localStorage.setItem('token', data.token)
      localStorage.setItem('utente', JSON.stringify(this.utente))
    },
    logout() {
      this.token = null
      this.utente = null
      this.menu = []
      this.filiali = []
      localStorage.removeItem('token')
      localStorage.removeItem('utente')
    }
  }
})
