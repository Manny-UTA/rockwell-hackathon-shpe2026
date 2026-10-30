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
  const [asked, setAsked] = useState(null)
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
      setAsked(values)
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
        {card?.found && !loading && asked && <ConfirmCause key={JSON.stringify(asked)} card={card} asked={asked} />}
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

// Feedback loop: after the repair, the technician confirms the actual cause. Agent 1 learns from it
// on the next weekly job run, and the Improve tab tracks live accuracy from these answers.
function ConfirmCause({ card, asked }) {
  const [causes, setCauses] = useState([])
  const [f, setF] = useState({ actual_cause: '', order_number: '', manual_helpful: null, comment: '' })
  const [state, setState] = useState({ saving: false, done: null, error: null })

  useEffect(() => {
    api('/causes').then((d) => setCauses(d.causes)).catch(() => {})
  }, [])

  const predicted = card.causes.map((c) => c.cause)
  async function submit(e) {
    e.preventDefault()
    if (!f.actual_cause) return setState({ ...state, error: 'Pick the cause you found.' })
    setState({ saving: true, done: null, error: null })
    try {
      const r = await api('/feedback', {
        method: 'POST',
        body: { ...asked, ...f, predicted, confidence: card.confidence, level: card.level },
      })
      setState({ saving: false, done: r.verdict, error: null })
    } catch (err) {
      setState({ saving: false, done: null, error: err.message })
    }
  }

  if (state.done) {
    const msg = { top1: 'Our #1 pick was right.', top3: 'The cause was in our top 3.', missed: 'We missed this one, which is the most useful kind of feedback.' }
    return (
      <div className="loop-card done">
        <span className="loop-tag">FEEDBACK SAVED</span>
        <p><b>{msg[state.done]}</b> This case joins the patterns on the next weekly refresh, and it already counts in the Improve tab.</p>
      </div>
    )
  }

  return (
    <form className="loop-card" onSubmit={submit}>
      <span className="loop-tag">CLOSE THE LOOP</span>
      <h3>After the repair: what was the actual cause?</h3>
      <div className="loop-causes">
        {predicted.map((c, i) => (
          <button type="button" key={c} className={`chip ${f.actual_cause === c ? 'on' : ''}`}
            onClick={() => setF({ ...f, actual_cause: c })}>#{i + 1} {c}</button>
        ))}
        <select value={predicted.includes(f.actual_cause) ? '' : f.actual_cause}
          onChange={(e) => setF({ ...f, actual_cause: e.target.value })}>
          <option value="">Something else…</option>
          {causes.filter((c) => !predicted.includes(c)).map((c) => <option key={c}>{c}</option>)}
        </select>
      </div>
      <div className="loop-row">
        <span className="muted small">Did the manual procedure help?</span>
        {[['Yes', true], ['No', false]].map(([label, v]) => (
          <button type="button" key={label} className={`chip ${f.manual_helpful === v ? 'on' : ''}`}
            onClick={() => setF({ ...f, manual_helpful: f.manual_helpful === v ? null : v })}>{label}</button>
        ))}
      </div>
      <div className="loop-row">
        <input value={f.order_number} maxLength={20} placeholder="SAP order # (optional)"
          onChange={(e) => setF({ ...f, order_number: e.target.value })} />
        <input value={f.comment} maxLength={500} placeholder="Note for the team (optional)"
          onChange={(e) => setF({ ...f, comment: e.target.value })} />
      </div>
      <button className="primary" disabled={state.saving}>{state.saving ? 'Saving…' : 'Send feedback'}</button>
      {state.error && <div className="alert">{state.error}</div>}
    </form>
  )
}
