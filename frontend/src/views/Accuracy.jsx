import { useEffect, useState } from 'react'
import { api } from '../api'

const pct = (v) => (v == null ? '–' : `${Math.round(v * 100)}%`)
const list = (v) => {
  try { return JSON.parse(v).join(', ') } catch { return v ?? '' }
}

export default function Accuracy() {
  const [data, setData] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => {
    api('/accuracy').then(setData).catch((e) => setError(e.message))
  }, [])

  if (error) return <div className="alert">{error}</div>
  if (!data) return <p className="muted">Loading…</p>
  const s = data.summary

  return (
    <>
      <div className="tiles">
        <Tile label="Top-1 accuracy" value={pct(s.hit_at_1)} sub="First prediction was an actual cause" />
        <Tile label="Top-3 accuracy" value={pct(s.hit_at_3)} sub="Actual cause was in the top 3" accent />
        <Tile label="Baseline" value={pct(s.baseline)} sub="Always guessing the most common cause" />
        <Tile label="Eval cases" value={s.cases} sub="Held-out repair orders" />
      </div>

      <div className="card">
        <h3>Case results</h3>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Order</th><th>Catalog</th><th>Family</th><th>Symptom</th><th>Top prediction</th>
                <th>Actual cause(s)</th><th>Confidence</th><th>Matched at</th><th>Top-1</th><th>Top-3</th>
              </tr>
            </thead>
            <tbody>
              {data.rows.map((r) => (
                <tr key={`${r.order_number}-${r.line_number}`}>
                  <td>{r.order_number}-{r.line_number}</td>
                  <td>{r.catalog}</td>
                  <td>{r.family}</td>
                  <td>{r.symptom ?? <span className="muted">vague</span>}</td>
                  <td title={list(r.predicted_top3)}>{JSON.parse(r.predicted_top3 || '[]')[0]}</td>
                  <td>{list(r.actual_causes)}</td>
                  <td><span className={`badge conf-${r.confidence?.toLowerCase()}`}>{r.confidence}</span></td>
                  <td className="muted">{r.level_used}</td>
                  <td><Hit v={r.hit_at_1} /></td>
                  <td><Hit v={r.hit_at_3} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </>
  )
}

function Tile({ label, value, sub, accent }) {
  return (
    <div className={`card tile ${accent ? 'accent' : ''}`}>
      <div className="tile-label">{label}</div>
      <div className="tile-value">{value}</div>
      <div className="muted">{sub}</div>
    </div>
  )
}

const Hit = ({ v }) => (v === 'true' ? <span className="hit">✓</span> : <span className="miss">✗</span>)
