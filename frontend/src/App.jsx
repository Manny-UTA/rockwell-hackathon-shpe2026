import { useEffect, useState } from 'react'
import { api } from './api'
import Triage from './views/Triage'
import Chat from './views/Chat'
import Accuracy from './views/Accuracy'
import RepeatReturns from './views/RepeatReturns'
import Patterns from './views/Patterns'
import Simulator from './views/Simulator'
import Recommendations from './views/Recommendations'
import Improve from './views/Improve'

const TABS = [
  { id: 'triage', label: 'Triage', icon: '01', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: Triage,
    blurb: 'Enter an incoming unit to get likely causes, parts to stage, and areas to inspect.' },
  { id: 'simulator', label: 'Simulator', icon: '02', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: Simulator,
    blurb: 'Follow one repair through the three agents: extract, find patterns, and check the result.' },
  { id: 'chat', label: 'Assistant', icon: '03', needs: 'chat', env: 'AGENT_ENDPOINT', View: Chat,
    blurb: 'Ask about a unit, repair history, or depot operations.' },
  { id: 'recommendations', label: 'Recommendations', icon: '04', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: Recommendations,
    blurb: 'What to do for each likely cause in a product family, from the synthetic troubleshooting manual, with the family\'s risk scorecard.' },
  { id: 'patterns', label: 'Patterns', icon: '05', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: Patterns,
    blurb: 'Historical failure causes and the parts used to fix them, by product family.' },
  { id: 'accuracy', label: 'Accuracy', icon: '06', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: Accuracy,
    blurb: 'How often the triage card predicted the actual cause, compared with the baseline.' },
  { id: 'repeats', label: 'Repeat Returns', icon: '07', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: RepeatReturns,
    blurb: 'Serial numbers that have come back after a prior repair.' },
  { id: 'improve', label: 'Improve', icon: '08', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: Improve,
    blurb: 'The feedback loop: technicians confirm causes, the agents re-learn weekly, and the backlog shows what to fix next.' },
]

export default function App() {
  const [config, setConfig] = useState(null)
  const [error, setError] = useState(null)
  const [tab, setTab] = useState('triage')

  useEffect(() => {
    api('/config').then(setConfig).catch((e) => setError(e.message))
  }, [])

  const current = TABS.find((t) => t.id === tab)
  const enabled = config?.features?.[current.needs]

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="logo" aria-hidden="true"><span /></span>
          <span className="brand-copy"><strong>{config?.title ?? 'Repair Triage'}</strong><small>DEPOT INTELLIGENCE</small></span>
        </div>
        <div className="nav-label">WORKSPACE / 2026</div>
        <nav>
          {TABS.map((t) => (
            <button
              key={t.id}
              className={`nav-item ${tab === t.id ? 'active' : ''}`}
              onClick={() => setTab(t.id)}
            >
              <span className="nav-index">{t.icon}</span>
              {t.label}
              {config && !config.features[t.needs] && <span className="dot" title="Not configured" />}
            </button>
          ))}
        </nav>
        <div className="sidebar-foot"><span className="sidebar-foot-line" />SHPE 2026 <span>·</span> DATABRICKS</div>
      </aside>

      <main className="content">
        <header className="page-head">
          <div className="page-meta"><span>REPAIR OPERATIONS</span><span>/{current.icon}</span></div>
          <h1>{current.label}<span className="title-period">.</span></h1>
          <p>{current.blurb}</p>
        </header>
        {error && <div className="alert">Could not reach backend: {error}</div>}
        {config && !enabled && (
          <div className="empty">
            <h3>Not configured yet</h3>
            <p>Set <code>{current.env}</code> in <code>app.yaml</code> to enable this tab.</p>
          </div>
        )}
        {config && enabled && <current.View onNavigate={setTab} />}
      </main>
    </div>
  )
}
