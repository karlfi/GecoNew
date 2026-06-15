import dagre from '@dagrejs/dagre'

// Dispone i nodi della macchina a stati a livelli (sinistra -> destra) con dagre.
// nodi: [{stato, ...}], archi: [{statoInizio, statoFine, ...}]
// Restituisce una mappa stato -> {x, y}.
export function layoutStati(nodi, archi, { nodeW = 170, nodeH = 54 } = {}) {
  const g = new dagre.graphlib.Graph()
  g.setGraph({ rankdir: 'LR', nodesep: 30, ranksep: 90, marginx: 20, marginy: 20 })
  g.setDefaultEdgeLabel(() => ({}))

  for (const n of nodi) g.setNode(n.stato, { width: nodeW, height: nodeH })
  for (const a of archi) {
    if (a.statoInizio && a.statoFine && a.statoInizio !== a.statoFine) {
      g.setEdge(a.statoInizio, a.statoFine)
    }
  }

  dagre.layout(g)

  const pos = {}
  for (const n of nodi) {
    const gn = g.node(n.stato)
    if (gn) pos[n.stato] = { x: gn.x - nodeW / 2, y: gn.y - nodeH / 2 }
  }
  return pos
}
