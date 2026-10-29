import { useEffect, useRef, useState } from 'react'
import { api } from '../api'

const STARTERS = [
  'Triage catalog R2094BM02S/D with an E39 fault on power up',
  'Has serial SN-K6-001 been repaired before?',
  'Which product families have the most repair orders?',
]

export default function Chat() {
  const [messages, setMessages] = useState([])
  const [input, setInput] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)
  const bottom = useRef(null)

  useEffect(() => bottom.current?.scrollIntoView({ behavior: 'smooth' }), [messages, loading])

  async function send(e, preset) {
    e?.preventDefault()
    const text = (preset ?? input).trim()
    if (!text || loading) return
    const next = [...messages, { role: 'user', content: text }]
    setMessages(next)
    setInput('')
    setLoading(true)
    setError(null)
    try {
      const { reply } = await api('/chat', { method: 'POST', body: { messages: next } })
      setMessages([...next, { role: 'assistant', content: reply }])
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="chat card">
      <div className="chat-log">
        {messages.length === 0 && (
          <div className="starters">
            <p className="muted">Ask the triage assistant, for example:</p>
            {STARTERS.map((q) => (
              <button key={q} className="chip" onClick={() => send(null, q)}>{q}</button>
            ))}
          </div>
        )}
        {messages.map((m, i) => (
          <div key={i} className={`bubble ${m.role}`}>{m.content}</div>
        ))}
        {loading && <div className="bubble assistant typing">Checking repair history…</div>}
        <div ref={bottom} />
      </div>
      {error && <div className="alert">{error}</div>}
      <form className="chat-input" onSubmit={send}>
        <input value={input} onChange={(e) => setInput(e.target.value)} placeholder="Describe a unit or ask about repair operations…" />
        <button className="primary" disabled={loading || !input.trim()}>Send</button>
      </form>
    </div>
  )
}
