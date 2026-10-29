import { useEffect, useRef, useState } from 'react'
import { api } from '../api'
import { TriageCard } from './Triage'

const STAGES = [
  { key: 'raw', label: 'SAP report', icon: '00', sub: 'Raw repair order line' },
  { key: 'agent1', label: 'Agent 1 · Extract', icon: '01', sub: 'Structures the report' },
  { key: 'agent2', label: 'Agent 2 · Patterns', icon: '02', sub: 'Matches history, recommends' },
  { key: 'agent3', label: 'Agent 3 · Insights', icon: '03', sub: 'Checks results, feeds dashboards' },
]

export default function Simulator() {
  const [handoffs, setHandoffs] = useState([])
  const [samples, setSamples] = useState([])
  const [result, setResult] = useState(null)
  const [step, setStep] = useState(0)
  const [playing, setPlaying] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)
  const [custom, setCustom] = useState({ catalog: '', serial: '', failure_text: '' })
  const bottom = useRef(null)

  useEffect(() => {
    api('/agents').then((d) => setHandoffs(d.handoffs)).catch(() => {})
    api('/simulate/samples').then((d) => setSamples(d.samples)).catch((e) => setError(e.message))
  }, [])

  // Auto-advance while playing
  useEffect(() => {
    if (!playing || !result) return
    if (step >= STAGES.length - 1) return setPlaying(false)
    const t = setTimeout(() => setStep((s) => s + 1), 1600)
    return () => clearTimeout(t)
  }, [playing, step, result])

  useEffect(() => {
    if (result) bottom.current?.scrollIntoView({ behavior: 'smooth', block: 'end' })
  }, [step, result])

  async function load(promise) {
    setLoading(true)
    setError(null)
    setResult(null)
    setStep(0)
    setPlaying(false)
    try {
      setResult(await promise)
    } catch (e) {
      setError(e.message)
    } finally {
      setLoading(false)
    }
  }

  const runSample = (s) => load(api(`/simulate/${encodeURIComponent(s.order_number)}/${s.line_number}`))
  const runCustom = (e) => {
    e.preventDefault()
    load(api('/simulate/custom', { method: 'POST', body: custom }))
  }

  const byAgent = (prefix) => handoffs.filter((h) => h.agent.startsWith(prefix))

  return (
    <>
      <section className="card flow">
        <h3>How the agents work together</h3>
        <p className="muted">Each agent writes tables the next one reads. Counts are from the latest run of the repair-triage-agents job.</p>
        <div className="flow-row">
          <FlowNode icon="00" title="SAP repair orders" active={result && step === 0}
            lines={['ultraviolet.shpe.sap_economy_repair_order_lines']} />
          <Arrow />
          <FlowNode icon="01" title="Agent 1 · Extract" active={result && step === 1} lines={byAgent('1').map((h) => h.summary)} />
          <Arrow />
          <FlowNode icon="02" title="Agent 2 · Patterns" active={result && step === 2} lines={byAgent('2').map((h) => h.summary)} />
          <Arrow />
          <FlowNode icon="03" title="Agent 3 · Insights" active={result && step === 3} lines={byAgent('3').map((h) => h.summary)} />
        </div>
      </section>

      <div className="sim">
        <section className="card sim-pick">
          <h3>Pick a real 2026 repair</h3>
          <p className="muted">Agent 3 never saw these when it learned the patterns, so you can see whether the prediction holds up.</p>
          <div className="sample-list">
            {samples.map((s) => (
              <button key={`${s.order_number}-${s.line_number}`} className="sample" onClick={() => runSample(s)} disabled={loading}>
                <span className="sample-story">{s.story}</span>
                <span className="muted">{s.family} · {s.symptom ?? 'vague complaint'}</span>
              </button>
            ))}
          </div>
          <h3 className="or">…or simulate a new unit</h3>
          <form onSubmit={runCustom} className="sim-form">
            <input placeholder="Catalog, e.g. R2711PT15C22D9P/A" value={custom.catalog} onChange={(e) => setCustom({ ...custom, catalog: e.target.value })} />
            <input placeholder="Serial (optional)" value={custom.serial} onChange={(e) => setCustom({ ...custom, serial: e.target.value })} />
            <input placeholder="Customer complaint, e.g. screen flickers" value={custom.failure_text} onChange={(e) => setCustom({ ...custom, failure_text: e.target.value })} />
            <button className="primary" disabled={loading || !custom.catalog.trim()}>Simulate</button>
          </form>
          {error && <div className="alert">{error}</div>}
        </section>

        <section className="sim-run">
          {!result && !loading && (
            <div className="card empty-sim">
              <p className="muted">Choose a repair to watch it move through the three agents.</p>
            </div>
          )}
          {loading && <div className="card empty-sim"><p className="muted">Pulling the report…</p></div>}
          {result && (
            <>
              <div className="stepper card">
                {STAGES.map((s, i) => (
                  <button key={s.key} className={`step ${i === step ? 'current' : ''} ${i < step ? 'done' : ''}`} onClick={() => { setPlaying(false); setStep(i) }}>
                    <span className="step-icon">{i < step ? '✓' : s.icon}</span>
                    <span className="step-text"><b>{s.label}</b><span className="muted">{s.sub}</span></span>
                  </button>
                ))}
                <div className="step-actions">
                  <button onClick={() => { setStep(0); setPlaying(true) }}>▶ Play all</button>
                  <button className="primary" disabled={step >= STAGES.length - 1} onClick={() => { setPlaying(false); setStep(step + 1) }}>
                    Next agent →
                  </button>
                </div>
              </div>

              <RawStage r={result} />
              {step >= 1 && <Agent1Stage r={result} />}
              {step >= 2 && <Agent2Stage r={result} />}
              {step >= 3 && <Agent3Stage r={result} />}
              <div ref={bottom} />
            </>
          )}
        </section>
      </div>
    </>
  )
}

function FlowNode({ icon, title, lines, active }) {
  return (
    <div className={`flow-node ${active ? 'active' : ''}`}>
      <div className="flow-title"><span>{icon}</span>{title}</div>
      {lines.length ? lines.map((l) => <div key={l} className="flow-line">{l}</div>) : <div className="flow-line muted">No run logged yet</div>}
    </div>
  )
}

const Arrow = () => <div className="flow-arrow">→</div>

function Stage({ n, title, children }) {
  return (
    <div className="card stage">
      <div className="stage-head"><span className="stage-n">{n}</span><h3>{title}</h3></div>
      {children}
    </div>
  )
}

function Field({ label, children }) {
  return <><dt>{label}</dt><dd>{children ?? <span className="muted">—</span>}</dd></>
}

const Chips = ({ items, empty = 'none recorded' }) =>
  items?.length ? <span className="chips">{items.map((i) => <span key={i} className="pill">{i}</span>)}</span> : <span className="muted">{empty}</span>

function RawStage({ r }) {
  const raw = r.raw
  return (
    <Stage n="00" title={r.mode === 'order' ? `SAP report · order ${raw.order_number}-${raw.line_number}` : 'New unit at intake'}>
      <dl className="kv-grid">
        <Field label="Catalog">{raw.catalog}</Field>
        {raw.part_description && <Field label="Description">{raw.part_description}</Field>}
        <Field label="Serial">{raw.serial_number}</Field>
        {raw.order_submit_date && <Field label="Submitted">{raw.order_submit_date}</Field>}
        <Field label="Failure details"><span className="mono">{raw.failure_details}</span></Field>
        {r.mode === 'order' && <Field label="Cause code (tech)"><span className="mono">{raw.probable_cause_code}</span></Field>}
        {r.mode === 'order' && <Field label="Parts replaced"><span className="mono small">{raw.parts_replaced}</span></Field>}
      </dl>
      {r.mode === 'order' && <p className="muted note">Free text and codes as typed into SAP. The cause and parts were only known after the repair; the triage card can't see them.</p>}
    </Stage>
  )
}

function Agent1Stage({ r }) {
  const a = r.agent1
  return (
    <Stage n="1" title="Agent 1 · Extract: structured record">
      <dl className="kv-grid">
        <Field label="Product family">{a.family}</Field>
        <Field label="Symptom">{a.symptom ?? <span className="muted">vague, no usable symptom</span>}</Field>
        <Field label="Cleaned complaint"><span className="mono">{a.failure_text}</span></Field>
        <Field label="Serial (normalized)">{a.serial}</Field>
        {r.mode === 'order' && <Field label="Confirmed causes"><Chips items={a.causes} empty="no cause code recorded" /></Field>}
        {r.mode === 'order' && <Field label="Parts (standardized)"><Chips items={a.parts} /></Field>}
        {r.mode === 'order' && <Field label="Areas affected"><Chips items={a.areas} /></Field>}
      </dl>
      <p className="muted note">Handed to Agent 2 as a row in silver_real.repair_orders_clean (plus repair_cause and repair_parts).</p>
    </Stage>
  )
}

function Agent2Stage({ r }) {
  return (
    <Stage n="2" title="Agent 2 · Patterns: triage card">
      {r.agent2.found ? <TriageCard card={r.agent2} /> : <p className="muted">No historical pattern found.</p>}
      {r.mode === 'order' && (
        <p className="muted note">
          This is the card a technician sees today, built from all history. Agent 3's check below re-runs the
          prediction using only 2023–2025 data, so this repair can't influence its own result.
        </p>
      )}
    </Stage>
  )
}

function Agent3Stage({ r }) {
  const ev = r.agent3.eval
  const f = r.agent3.family
  const top3 = ev ? JSON.parse(ev.predicted_top3 || '[]') : []
  const actual = ev ? JSON.parse(ev.actual_causes || '[]') : []
  return (
    <Stage n="3" title="Agent 3 · Insights: did it hold up?">
      {ev ? (
        <>
          <p className="muted">Prediction made from 2023–2025 history only, compared with what the technician actually found:</p>
          <div className="verdict-grid">
            <div>
              <div className="eyebrow">Predicted (top 3)</div>
              <ol className="mini-list">{top3.map((c) => <li key={c} className={actual.includes(c) ? 'match' : ''}>{c}</li>)}</ol>
            </div>
            <div>
              <div className="eyebrow">Actual cause</div>
              <Chips items={actual} />
            </div>
            <div className="verdict">
              <span className={`badge ${ev.hit_at_1 === 'true' ? 'ok' : 'bad'}`}>Top-1 {ev.hit_at_1 === 'true' ? '✓' : '✗'}</span>
              <span className={`badge ${ev.hit_at_3 === 'true' ? 'ok' : 'bad'}`}>Top-3 {ev.hit_at_3 === 'true' ? '✓' : '✗'}</span>
              <span className="muted small">Baseline guess "{ev.baseline_cause}": {ev.baseline_hit === 'true' ? '✓' : '✗'}</span>
            </div>
          </div>
        </>
      ) : (
        <p className="muted">New unit: there is no outcome yet. Once it's repaired, Agent 3 scores the card against what the technician found.</p>
      )}
      {f && (
        <>
          <div className="eyebrow scorecard-title">{f.family} scorecard (feeds the Patterns and Accuracy dashboards)</div>
          <div className="scorecard">
            <Stat label="Order lines" value={Number(f.order_lines).toLocaleString()} />
            <Stat label="Top cause" value={`${f.top_cause ?? '—'}`} sub={f.top_cause_pct ? `${Math.round(f.top_cause_pct)}% of labeled` : ''} />
            <Stat label="No problem found" value={f.no_problem_found_pct != null ? `${f.no_problem_found_pct}%` : '—'} />
            <Stat label="Repeat-return serials" value={Number(f.repeat_serials).toLocaleString()} />
            <Stat label="Median repair time" value={f.median_cycle_days != null ? `${f.median_cycle_days} days` : '—'} sub="received → complete" />
            <Stat label="Avg net price" value={f.avg_net_price ? `$${Number(f.avg_net_price).toLocaleString()}` : '—'} />
          </div>
        </>
      )}
    </Stage>
  )
}

function Stat({ label, value, sub }) {
  return (
    <div className="stat">
      <div className="muted small">{label}</div>
      <div className="stat-value">{value}</div>
      {sub && <div className="muted small">{sub}</div>}
    </div>
  )
}
