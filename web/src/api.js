import axios from 'axios'

const api = axios.create({ baseURL: '/api' })

api.interceptors.request.use(cfg => {
  const token = localStorage.getItem('token')
  if (token) cfg.headers.Authorization = `Bearer ${token}`
  return cfg
})

api.interceptors.response.use(
  r => r,
  err => {
    // token scaduto o non valido: torna al login
    if (err.response?.status === 401 && location.pathname !== '/login') {
      localStorage.removeItem('token')
      localStorage.removeItem('utente')
      location.href = '/login'
    }
    return Promise.reject(err)
  }
)

export default api
