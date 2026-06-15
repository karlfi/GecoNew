// Converte l'elenco piatto di ElencoMenuGruppi nel modello PanelMenu di PrimeVue.
// La struttura è ad albero a DUE livelli:
//   - root  = ParentID 0 o nullo (sezione, non cliccabile)
//   - foglia = ParentID valorizzato (apre la videata)
// Sezioni e foglie sono ordinate per il campo `sorting` calcolato dalla SP.
export function buildMenuTree(voci, naviga, filtro = '', idAttivo = '') {
  const f = filtro.trim().toLowerCase()
  const radici = []
  const byId = new Map()

  for (const v of voci) {
    if (!v.ParentID) {
      const nodo = { key: String(v.ID), label: v.Text, sorting: Number(v.sorting ?? 0), items: [] }
      byId.set(v.ID, nodo)
      radici.push(nodo)
    }
  }

  for (const v of voci) {
    if (!v.ParentID) continue
    if (f && !(v.Text ?? '').toLowerCase().includes(f)) continue
    const parent = byId.get(v.ParentID)
    if (!parent) continue // foglia orfana: ParentID che non esiste tra le root
    // foglia "migrata" = ha un Link valorizzato; altrimenti è ancora da migrare
    const migrata = !!(v.Link && String(v.Link).trim())
    const classi = [
      String(v.ID) === idAttivo ? 'voce-attiva' : '',
      migrata ? 'voce-migrata' : 'voce-da-migrare'
    ].filter(Boolean).join(' ')
    parent.items.push({
      key: String(v.ID),
      label: v.Text,
      sorting: Number(v.sorting ?? 0),
      class: classi || undefined,
      migrata,
      command: () => naviga(v)
    })
  }

  for (const r of radici) r.items.sort((a, b) => a.sorting - b.sorting)

  // niente sezioni vuote (utile anche quando il filtro non trova nulla).
  // NB: per le sezioni di primo livello la SP calcola sorting = 100 - Sorting,
  // quindi l'ordine giusto e' il DECRESCENTE (le foglie restano crescenti).
  return radici
    .filter(r => r.items.length > 0)
    .sort((a, b) => b.sorting - a.sorting)
}
