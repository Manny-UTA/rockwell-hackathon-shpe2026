import { useEffect, useState } from 'react'
import { api } from '../api'

export default function Patterns() {
  const [data, setData] = useState(null)
  const [family, setFamily] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => {
    api('/patterns')
      .then((d) => {
        setData(d)
        setFamily(d.causes[0]?.family ?? null)
      })
      .catch((e) => setError(e.message))
  }, [])

  if (error) return <div className="alert">{error}</div>
  if (!data) return <p className="muted">Loading…</p>

  // One entry per family with its labeled case count, largest first
  const families = [...new Map(data.causes.map((c) => [c.family, Number(c.total)])).entries()]
  const causes = data.causes.filter((c) => c.family === family).slice(0, 8)
  const total = families.find(([f]) => f === family)?.[1] ?? 0

  return (
    <>
      <div className="family-picker">
        {families.slice(0, 8).map(([f, n]) => (
          <button key={f} className={`chip ${f === family ? 'selected' : ''}`} onClick={() => setFamily(f)}>
            {f} <span className="muted">{n.toLocaleString()}</span>
          </button>
        ))}
        <select value={family ?? ''} onChange={(e) => setFamily(e.target.value)}>
          {families.map(([f, n]) => <option key={f} value={f}>{f} ({n.toLocaleString()})</option>)}
        </select>
      </div>

      <div className="grid-2">
        <section className="card">
          <h3>Root causes</h3>
          <p className="muted">
            Share of {total.toLocaleString()} labeled {family} repairs with each cause (a repair can have several)
          </p>
          <ul className="share-list">
            {causes.map((c, i) => {
              const share = (Number(c.cases) / Number(c.total)) * 100
              return (
                <li key={c.cause}>
                  <div className="cause-row">
                    <span className="cause-name">{c.cause}</span>
                    <span className="pct">{share.toFixed(0)}%</span>
                  </div>
                  <div className={`bar flush ${i ? 'secondary' : ''}`}><div style={{ width: `${share}%` }} /></div>
                  <span className="muted">{Number(c.cases).toLocaleString()} cases</span>
                </li>
              )
            })}
          </ul>
        </section>

        <div className="stack">
          <UsageCard title="Parts replaced" subtitle="Part types technicians replaced" rows={data.parts} field="part" family={family} />
          <UsageCard title="Areas affected" subtitle="Where technicians found the damage" rows={data.areas} field="area" family={family} />
        </div>
      </div>
    </>
  )
}

function UsageCard({ title, subtitle, rows, field, family }) {
  // Collapse across causes: total usage per item, plus its most common cause
  const byItem = new Map()
  for (const r of rows.filter((r) => r.family === family)) {
    const e = byItem.get(r[field]) ?? { item: r[field], count: 0, topCause: r.cause, topCount: 0 }
    e.count += Number(r.count)
    if (Number(r.count) > e.topCount) Object.assign(e, { topCause: r.cause, topCount: Number(r.count) })
    byItem.set(r[field], e)
  }
  const items = [...byItem.values()].sort((a, b) => b.count - a.count).slice(0, 8)
  const max = Math.max(...items.map((i) => i.count), 1)

  return (
    <section className="card">
      <h3>{title}</h3>
      <p className="muted">{subtitle}</p>
      {items.length === 0 ? (
        <p className="muted">No data recorded for this family.</p>
      ) : (
        <table className="parts">
          <thead><tr><th>{field === 'part' ? 'Part' : 'Area'}</th><th>Most often for</th><th className="num">Repairs</th></tr></thead>
          <tbody>
            {items.map((i) => (
              <tr key={i.item}>
                <td><b>{i.item}</b></td>
                <td className="muted">{i.topCause}</td>
                <td className="num">
                  <span className="mini-bar"><span style={{ width: `${(i.count / max) * 100}%` }} /></span>
                  {i.count.toLocaleString()}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}
