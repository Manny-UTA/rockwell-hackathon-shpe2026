import { useEffect, useState } from 'react'
import { api } from '../api'

export default function RepeatReturns() {
  const [rows, setRows] = useState(null)
  const [filter, setFilter] = useState('')
  const [error, setError] = useState(null)

  useEffect(() => {
    api('/repeat-returns').then((d) => setRows(d.rows)).catch((e) => setError(e.message))
  }, [])

  if (error) return <div className="alert">{error}</div>
  if (!rows) return <p className="muted">Loading…</p>

  const q = filter.toLowerCase()
  const shown = rows.filter((r) => !q || Object.values(r).some((v) => String(v ?? '').toLowerCase().includes(q)))

  return (
    <div className="card">
      <div className="toolbar">
        <input placeholder="Search serial, order, cause…" value={filter} onChange={(e) => setFilter(e.target.value)} />
        <span className="muted">{shown.length} units</span>
      </div>
      <div className="table-wrap">
        <table>
          <thead>
            <tr><th>Serial</th><th>Prior repairs</th><th>Last order</th><th>Last repair date</th><th>Prior cause</th><th>Parts replaced</th></tr>
          </thead>
          <tbody>
            {shown.map((r) => (
              <tr key={r.serial}>
                <td><b>{r.serial}</b></td>
                <td><span className={`badge ${Number(r.prior_repairs) > 1 ? 'bad' : 'pending'}`}>{r.prior_repairs}×</span></td>
                <td>{r.prior_order_number}</td>
                <td>{r.prior_repair_date}</td>
                <td>{r.prior_cause}</td>
                <td>{r.prior_parts}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
