import { useEffect, useState } from 'react'
import { api } from '../api'
import { ManualSteps } from './Recommendations'

const EXAMPLES = [
  { label: 'PanelView touchscreen', catalog: 'R2711PT15C22D9P/A', serial: '', failure_text: 'Touchscreen not responding' },
  { label: 'Kinetix repeat unit', catalog: 'R2094BM02S/D', serial: '44657535', failure_text: 'E39 fault on power up' },
  { label: 'Servo motor noise', catalog: 'RMPMB2152MSJ74AA/A', serial: '', failure_text: 'Loud grinding noise when running' },
  { label: 'Vague report', catalog: 'R1756L72/B', serial: '', failure_text: 'Unit is defective' },
]

export default function Triage() {
  const [catalogs, setCatalogs] = useState([])
  const [form, setForm] = useState({ catalog: '', serial: '', failure_text: '' })
  const [card, setCard] = useState(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)

  useEffect(() => {
    api('/catalogs').then((d) => setCatalogs(d.catalogs)).catch(() => {})
  }, [])

  async function run(values = form) {
    if (!values.catalog.trim()) return setError('Catalog number is required.')
    setLoading(true)
    setError(null)
    try {
      setCard(await api('/triage', { method: 'POST', body: values }))
    } catch (e) {
      setError(e.message)
      setCard(null)
    } finally {
      setLoading(false)
    }
  }

  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value })
  const family = catalogs.find((c) => c.catalog === form.catalog)?.family

  return (
    <div className="triage">
      <form className="card intake" onSubmit={(e) => { e.preventDefault(); run() }}>
        <h3>Incoming unit</h3>
        <label>
          Catalog number
          <input list="catalogs" value={form.catalog} onChange={set('catalog')} placeholder="e.g. R2094BM02S/D" />
          <datalist id="catalogs">
            {catalogs.map((c) => <option key={c.catalog} value={c.catalog}>{c.family}</option>)}
          </datalist>
          {family && <span className="hint">✓ {family}</span>}
        </label>
        <label>
          <span>Serial number <span className="muted">(optional)</span></span>
          <input value={form.serial} onChange={set('serial')} placeholder="e.g. 44657535" />
        </label>
        <label>
          <span>Customer failure description <span className="muted">(optional)</span></span>
          <textarea rows={3} value={form.failure_text} onChange={set('failure_text')} placeholder="e.g. Touchscreen not responding" />
        </label>
        <button className="primary" disabled={loading}>{loading ? 'Triaging…' : 'Get triage card'}</button>
        <div className="examples">
          <span className="muted">Try:</span>
          {EXAMPLES.map((ex) => (
            <button type="button" key={ex.label} className="chip" onClick={() => { setForm(ex); run(ex) }}>
              {ex.label}
            </button>
          ))}
        </div>
        {error && <div className="alert">{error}</div>}
      </form>

      <section className="card result">
        {!card && !loading && <p className="muted center">The triage card will appear here.</p>}
        {loading && <p className="muted center">Looking up historical patterns…</p>}
        {card && !card.found && !loading && (
          <p className="muted center">No historical pattern found for this catalog number.</p>
        )}
        {card?.found && !loading && <TriageCard card={card} />}
      </section>
    </div>
  )
}

export function TriageCard({ card }) {
  return (
    <>
      <div className="card-head">
        <div>
          <div className="eyebrow">
            {card.family ? `${card.family}${card.symptom ? ` · ${card.symptom}` : ''}` : 'Unknown catalog · depot-wide rates'}
          </div>
          <h2>Likely causes</h2>
        </div>
        <span className={`badge conf-${card.confidence?.toLowerCase()}`}>{card.confidence} confidence</span>
      </div>

      {card.repeat_warning && <div className="warning">⚠️ {card.repeat_warning}</div>}

      <ol className="causes">
        {card.causes.map((c) => (
          <li key={c.rank}>
            <div className="cause-row">
              <span className="rank">{c.rank}</span>
              <span className="cause-name">{c.cause}</span>
              <span className="pct">{c.share_pct.toFixed(0)}%</span>
            </div>
            <div className="bar"><div style={{ width: `${c.share_pct}%` }} /></div>
            <dl className="cause-detail">
              {c.parts && <><dt>Stage parts</dt><dd>{c.parts}</dd></>}
              {c.areas && <><dt>Inspect</dt><dd>{c.areas}</dd></>}
            </dl>
            <ManualSteps rec={c.recommendation} />
          </li>
        ))}
      </ol>

      <p className="muted foot">
        Based on {card.cases} past cases matched at the <b>{card.level}</b> level. Procedures are from the synthetic
        troubleshooting manual (hackathon stand-in, not Rockwell documentation).
      </p>
    </>
  )
}
