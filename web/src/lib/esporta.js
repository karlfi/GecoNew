// Scarica un file dall'API (passa dal client axios, quindi col token) e lo
// consegna al browser col nome che dice il server, o quello di riserva.
export async function scaricaDaApi(api, url, params, nomeRiserva) {
  const r = await api.get(url, { params, responseType: 'blob' })
  const disposizione = r.headers?.['content-disposition'] || ''
  const m = /filename\*=UTF-8''([^;]+)|filename="?([^";]+)"?/i.exec(disposizione)
  const nome = m ? decodeURIComponent(m[1] || m[2]) : nomeRiserva
  const a = document.createElement('a')
  a.href = URL.createObjectURL(r.data)
  a.download = nome
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(a.href), 5000)
}
