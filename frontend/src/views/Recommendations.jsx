import { useEffect, useState } from 'react'
import { api } from '../api'

export default function Recommendations() {
  const [data, setData] = useState(null)
  const [family, setFamily] = useState(null)
  const [error, setError] = useState(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    setLoading(true)
    api(`/recommendations${family ? `?family=${encodeURIComponent(family)}` : ''}`)
      .then((d) => {
        setData(d)
        setError(null)
      })
      .catch((e) => setError(e.message))
      .finally(() => setLoading(false))
  }, [family])

  if (error) return <div className="alert">{error}</div>
  if (!data) return <p className="muted">Loading…</p>
  if (!data.families.length) return <p className="muted">No recommendations yet. Run the repair-triage-agents job.</p>

  const { insight, depot, accuracy } = data
  const current = data.family

  return (
    <>
      <div className="family-picker">
        {data.families.slice(0, 8).map((f) => (
          <button key={f.family} className={`chip ${f.family === current ? 'selected' : ''}`} onClick={() => setFamily(f.family)}>
            {f.family} <span className="muted">{Number(f.order_lines).toLocaleString()}</span>
          </button>
        ))}
        <select value={current} onChange={(e) => setFamily(e.target.value)}>
          {data.families.map((f) => <option key={f.family} value={f.family}>{f.family} ({Number(f.order_lines).toLocaleString()})</option>)}
        </select>
      </div>

      {insight && (
        <div className="tiles">
          <RiskTile label="No Problem Found rate" value={insight.no_problem_found_pct} ref_={depot.no_problem_found_pct} unit="%" />
          <RiskTile label="Vague complaints" value={insight.vague_complaint_pct} ref_={depot.vague_complaint_pct} unit="%" />
          <RiskTile label="Median repair cycle" value={insight.median_cycle_days} ref_={depot.median_cycle_days} unit=" days" />
          <div className="card tile">
            <div className="tile-label">Triage accuracy (2026 holdout)</div>
            <div className="tile-value">{accuracy.top3 ?? '–'}%</div>
            <div className="muted small">top-3 · top-1 {accuracy.top1 ?? '–'}% · {Number(accuracy.n).toLocaleString()} repairs</div>
          </div>
        </div>
      )}

      <section className="card">
        <div className="card-head">
          <div>
            <div className="eyebrow">{current} · {Number(insight?.labeled_lines ?? 0).toLocaleString()} labeled repairs · {Number(insight?.repeat_serials ?? 0).toLocaleString()} repeat-return serials</div>
            <h2>What to do, by likely cause</h2>
          </div>
          <span className="badge pending" title="ZS-authored stand-in for hackathon use, not Rockwell documentation">Synthetic manual</span>
        </div>
        {loading && <p className="muted">Loading…</p>}
        <ol className="causes">
          {data.recommendations.filter((r) => r.share_pct >= 1).map((r, i) => (
            <li key={r.cause}>
              <div className="cause-row">
                <span className="rank">{i + 1}</span>
                <span className="cause-name">{r.cause}</span>
                <span className="pct">{r.share_pct.toFixed(0)}%</span>
              </div>
              <div className={`bar ${i ? 'secondary' : ''}`}><div style={{ width: `${r.share_pct}%` }} /></div>
              <ManualSteps rec={r} detail={`${r.cases.toLocaleString()} of ${r.family_cases.toLocaleString()} repairs`} />
            </li>
          ))}
        </ol>
        <p className="muted foot">
          Procedures come from the <b>Synthetic Troubleshooting Manual</b>, a ZS-authored hackathon stand-in, not Rockwell
          documentation. Each is matched by the cause and the area technicians most often reported for it; causes without a
          section fall back to the general troubleshooting protocol.
        </p>
      </section>
    </>
  )
}

function RiskTile({ label, value, ref_, unit }) {
  const v = Number(value)
  const r = Number(ref_)
  const above = value != null && ref_ != null && v > r
  return (
    <div className="card tile">
      <div className="tile-label">{label}</div>
      <div className="tile-value" style={above ? { color: 'var(--bad)' } : undefined}>{value ?? '–'}{value != null && unit}</div>
      <div className="muted small">{above ? '▲ above' : 'at or below'} depot {r}{unit}</div>
    </div>
  )
}

export function ManualSteps({ rec, detail }) {
  if (!rec) return null
  return (
    <div className="manual">
      <div className="manual-head">
        {rec.section
          ? <><b>Manual §{rec.section}: {rec.title}</b>{rec.matched_area && <span className="muted"> · most reported area: {rec.matched_area}</span>}</>
          : <b>General troubleshooting protocol</b>}
        {detail && <span className="muted"> · {detail}</span>}
      </div>
      <ol className="manual-steps">
        {rec.steps.map((s) => <li key={s}>{s}</li>)}
      </ol>
    </div>
  )
}
