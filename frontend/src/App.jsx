import { useEffect, useState } from 'react'
import { api } from './api'
import Triage from './views/Triage'
import Chat from './views/Chat'
import Accuracy from './views/Accuracy'
import RepeatReturns from './views/RepeatReturns'
import Patterns from './views/Patterns'
import Simulator from './views/Simulator'
import Recommendations from './views/Recommendations'

const TABS = [
  { id: 'triage', label: 'Triage', icon: '🔧', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: Triage,
    blurb: 'Enter an incoming unit to get likely causes, parts to stage, and areas to inspect.' },
  { id: 'simulator', label: 'Simulator', icon: '🔁', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: Simulator,
    blurb: 'Follow one repair through the three agents: extract, find patterns, and check the result.' },
  { id: 'chat', label: 'Assistant', icon: '💬', needs: 'chat', env: 'AGENT_ENDPOINT', View: Chat,
    blurb: 'Ask about a unit, repair history, or depot operations.' },
  { id: 'recommendations', label: 'Recommendations', icon: '🛠️', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: Recommendations,
    blurb: 'What to do for each likely cause in a product family, from the synthetic troubleshooting manual, with the family\'s risk scorecard.' },
  { id: 'patterns', label: 'Patterns', icon: '🧩', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: Patterns,
    blurb: 'Historical failure causes and the parts used to fix them, by product family.' },
  { id: 'accuracy', label: 'Accuracy', icon: '📊', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: Accuracy,
    blurb: 'How often the triage card predicted the actual cause, compared with the baseline.' },
  { id: 'repeats', label: 'Repeat Returns', icon: '↩️', needs: 'data', env: 'DATABRICKS_WAREHOUSE_ID', View: RepeatReturns,
    blurb: 'Serial numbers that have come back after a prior repair.' },
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
          <span className="logo">◆</span>
          <span>{config?.title ?? 'Repair Triage'}</span>
        </div>
        <nav>
          {TABS.map((t) => (
            <button
              key={t.id}
              className={`nav-item ${tab === t.id ? 'active' : ''}`}
              onClick={() => setTab(t.id)}
            >
              <span>{t.icon}</span>
              {t.label}
              {config && !config.features[t.needs] && <span className="dot" title="Not configured" />}
            </button>
          ))}
        </nav>
        <div className="sidebar-foot">Powered by Databricks</div>
      </aside>

      <main className="content">
        <header className="page-head">
          <h1>{current.label}</h1>
          <p className="muted">{current.blurb}</p>
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
