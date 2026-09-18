// Una data per ExcelJS. ExcelJS scrive gli istanti in UTC: una mezzanotte
// italiana (UTC+2) diventava le 22:00 del giorno prima e in Excel si vedeva
// il giorno precedente. Qui la data si costruisce con i valori "di orologio",
// quelli che si vedono a video, messi in UTC: Excel mostra proprio quelli.
// Le stringhe con fuso (Z o +hh:mm) sono istanti veri: prima in ora locale.
export function dataExcel(v) {
  if (v instanceof Date) return new Date(Date.UTC(v.getFullYear(), v.getMonth(), v.getDate(), v.getHours(), v.getMinutes(), v.getSeconds()))
  if (typeof v !== 'string') return v
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?$/.exec(v)
  if (!m) return v
  if (m[7]) { const d = new Date(v); return isNaN(d) ? v : dataExcel(d) }
  return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] ?? 0), +(m[5] ?? 0), +(m[6] ?? 0)))
}
// il formato della cella: solo data se e' mezzanotte, altrimenti data e ora
export const formatoExcel = d => d.getUTCHours() === 0 && d.getUTCMinutes() === 0 && d.getUTCSeconds() === 0 ? 'dd/mm/yyyy' : 'dd/mm/yyyy hh:mm'
// aggiunge una riga a un foglio ExcelJS mettendo il formato alle celle con una data
export function rigaExcel(ws, valori) {
  const riga = ws.addRow(valori.map(dataExcel))
  riga.eachCell(c => { if (c.value instanceof Date) c.numFmt = formatoExcel(c.value) })
  return riga
}

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
