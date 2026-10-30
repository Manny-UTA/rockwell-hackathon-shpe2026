import { useEffect, useState } from 'react'
import { api } from '../api'

const LOOP = [
  ['Triage', 'Card predicts the top 3 causes'],
  ['Repair', 'Technician confirms the actual cause'],
  ['Learn', 'Weekly job re-runs Agents 1 → 2 → 3 with the new labels'],
  ['Measure', 'Live accuracy + backlog of what to fix next'],
]
const VERDICT = { top1: ['#1 right', 'ok'], top3: ['In top 3', 'pending'], missed: ['Missed', 'bad'] }
const share = (a, b) => (Number(b) ? `${Math.round((100 * Number(a)) / Number(b))}%` : '–')

export default function Improve() {
  const [data, setData] = useState(null)
  const [error, setError] = useState(null)
  const [area, setArea] = useState('All')

  useEffect(() => {
    api('/improvements').then(setData).catch((e) => setError(e.message))
  }, [])

  if (error) return <div className="alert">{error}</div>
  if (!data) return <p className="muted">Loading…</p>
  const fb = data.feedback
  const areas = ['All', ...new Set(data.backlog.map((b) => b.area))]
  const backlog = data.backlog.filter((b) => area === 'All' || b.area === area)

  return (
    <>
      <div className="card loop">
        <div className="loop-steps">
          {LOOP.map(([t, d], i) => (
            <div className="loop-step" key={t}>
              <span className="loop-n">{String(i + 1).padStart(2, '0')}</span>
              <b>{t}</b>
              <span className="muted small">{d}</span>
            </div>
          ))}
        </div>
        <p className="muted small loop-meta">
          Refresh: <b>{data.schedule}</b> · last run {data.last_run?.slice(0, 16) ?? '–'} ·{' '}
          {Number(fb.pending)} feedback answer{Number(fb.pending) === 1 ? '' : 's'} waiting for the next run
        </p>
      </div>

      <div className="tiles">
        <Tile label="Feedback received" value={Number(fb.submissions).toLocaleString()} sub="Confirmed causes from technicians" />
        <Tile label="Live top-3" value={share(fb.top3, fb.submissions)} sub={`vs ${data.holdout.top3}% on held-out 2026 repairs`} accent />
        <Tile label="Live top-1" value={share(fb.top1, fb.submissions)} sub={`vs ${data.holdout.top1}% on held-out 2026 repairs`} />
        <Tile label="Manual helped" value={share(fb.manual_yes, Number(fb.manual_yes) + Number(fb.manual_no))}
          sub={`${Number(fb.manual_yes) + Number(fb.manual_no)} answers`} />
      </div>

      <div className="card">
        <h3>Data sources the agents learn from</h3>
        <p className="muted small">
          Every source goes through one registry view (<code>silver_real.repair_lines_unified</code>). Adding another
          product line, a pre-2023 archive, or a new depot feed takes one mapping, and the next run picks it up.
        </p>
        <table>
          <thead><tr><th>Source</th><th className="num">Order lines</th><th className="num">Families</th><th>Covers</th></tr></thead>
          <tbody>
            {data.sources.map((s) => (
              <tr key={s.source_system}>
                <td><b>{s.source_system}</b></td>
                <td className="num">{Number(s.lines).toLocaleString()}</td>
                <td className="num">{s.families}</td>
                <td className="muted">{s.first_date} → {s.last_date}</td>
              </tr>
            ))}
            <tr className="muted">
              <td>+ Next source</td><td className="num">–</td><td className="num">–</td>
              <td>Other product lines · legacy archive · live depot feed</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div className="card">
        <div className="card-head">
          <div>
            <h3>Improvement backlog</h3>
            <p className="muted small">Ranked from the data and from technician feedback. Updates as new feedback arrives.</p>
          </div>
          <div className="chips">
            {areas.map((a) => (
              <button key={a} className={`chip ${area === a ? 'on' : ''}`} onClick={() => setArea(a)}>{a}</button>
            ))}
          </div>
        </div>
        <div className="table-wrap backlog">
          <table>
            <thead><tr><th className="num">#</th><th>Area</th><th>Family</th><th>Finding</th><th>Suggested action</th><th className="num">Repairs</th></tr></thead>
            <tbody>
              {backlog.map((b) => (
                <tr key={b.priority}>
                  <td className="num muted">{b.priority}</td>
                  <td><span className={`badge area-${b.area.toLowerCase()}`}>{b.area}</span></td>
                  <td>{b.family ?? <span className="muted">–</span>}</td>
                  <td>{b.finding}</td>
                  <td className="muted">{b.suggestion}</td>
                  <td className="num">{Number(b.repairs_affected).toLocaleString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className="card">
        <h3>Latest technician feedback</h3>
        {data.recent.length === 0 ? (
          <p className="muted">No feedback yet. After a repair, confirm the actual cause under the triage card.</p>
        ) : (
          <div className="table-wrap">
            <table>
              <thead><tr><th>When</th><th>Unit</th><th>Our #1</th><th>Actual</th><th>Result</th><th>Manual</th><th>Note</th></tr></thead>
              <tbody>
                {data.recent.map((r, i) => {
                  const [label, cls] = VERDICT[r.verdict] ?? [r.verdict, '']
                  return (
                    <tr key={i}>
                      <td className="muted">{r.submitted_at?.slice(0, 16)}</td>
                      <td>{r.catalog}<div className="muted">{r.family}</div></td>
                      <td>{r.predicted}</td>
                      <td><b>{r.actual_cause}</b></td>
                      <td><span className={`badge ${cls}`}>{label}</span></td>
                      <td>{r.manual_helpful == null ? <span className="muted">–</span> : r.manual_helpful === 'true' ? 'Yes' : 'No'}</td>
                      <td className="muted">{r.comment}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
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
