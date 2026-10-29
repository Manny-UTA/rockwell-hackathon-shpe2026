import { useEffect, useState } from 'react'
import { api } from '../api'

const LEVELS = {
  'catalog+symptom': 'Same catalog + symptom',
  'family+symptom': 'Same family + symptom',
  family: 'Same family',
  all: 'All repairs (no match)',
}
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
        <Tile label="Baseline" value={pct(s.baseline)} sub={`Always guessing "${s.baseline_cause}"`} />
        <Tile label="Eval cases" value={Number(s.cases).toLocaleString()} sub="2026 repairs, scored on 2023–2025 patterns" />
      </div>

      <div className="card by-level">
        <h3>By match level</h3>
        <p className="muted">
          How specific the historical match was for each repair. Most 2026 repairs match at the family level;
          groups under ~50 cases are too small to read much into.
        </p>
        <table>
          <thead><tr><th>Matched at</th><th className="num">Cases</th><th className="num">Top-1</th><th className="num">Top-3</th><th className="num">Baseline</th></tr></thead>
          <tbody>
            {data.by_level.map((l) => (
              <tr key={l.level_used}>
                <td>{LEVELS[l.level_used] ?? l.level_used}</td>
                <td className="num">{Number(l.cases).toLocaleString()}</td>
                <td className="num"><b>{pct(l.hit_at_1)}</b></td>
                <td className="num">{pct(l.hit_at_3)}</td>
                <td className="num muted">{pct(l.baseline)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card">
        <h3>Case results <span className="muted">(latest {data.rows.length})</span></h3>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Order</th><th>Unit</th><th>Symptom</th><th>Top prediction</th><th>Actual cause(s)</th>
                <th className="center-col">Top-1</th><th className="center-col">Top-3</th><th>Confidence</th><th>Matched at</th>
              </tr>
            </thead>
            <tbody>
              {data.rows.map((r) => (
                <tr key={`${r.order_number}-${r.line_number}`}>
                  <td>{r.order_number}-{r.line_number}</td>
                  <td>{r.catalog}<div className="muted">{r.family}</div></td>
                  <td>{r.symptom ?? <span className="muted">vague</span>}</td>
                  <td title={list(r.predicted_top3)}>{JSON.parse(r.predicted_top3 || '[]')[0]}</td>
                  <td>{list(r.actual_causes)}</td>
                  <td className="center-col"><Hit v={r.hit_at_1} /></td>
                  <td className="center-col"><Hit v={r.hit_at_3} /></td>
                  <td><span className={`badge conf-${r.confidence?.toLowerCase()}`}>{r.confidence}</span></td>
                  <td className="muted">{r.level_used}</td>
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
