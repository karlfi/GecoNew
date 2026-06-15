import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import AppShell from '../layout/AppShell.vue'
import LoginView from '../views/LoginView.vue'

// Due sole rotte: la navigazione tra le pagine interne avviene nello store nav
// senza toccare l'URL, che resta sempre sulla home (come il legacy).
const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', component: LoginView },
    { path: '/', component: AppShell },
    { path: '/:pathMatch(.*)*', redirect: '/' }
  ]
})

router.beforeEach(to => {
  const auth = useAuthStore()
  if (to.path !== '/login' && !auth.autenticato) return '/login'
  if (to.path === '/login' && auth.autenticato) return '/'
})

export default router
