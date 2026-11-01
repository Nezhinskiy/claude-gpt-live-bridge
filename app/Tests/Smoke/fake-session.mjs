// A fake Claude Code session for scripts/smoke.sh: it speaks the mod's side of the wire over the
// app's Unix socket (join, target, Start, a poll every second, one answer), records what the
// bridge reports, and checks the run.
//
//   node app/Tests/Smoke/fake-session.mjs <socket path> [deadline seconds]
//
// It answers the voice request once the call is back to `listening`, so the result arrives
// while the line is closed: a chime, then the voice speaks it after the owner's next line.
// Exit code 0 when every check passes; the timeline and the verdict go to stdout as JSON lines.
import { request } from 'node:http'

const [socketPath, deadlineArg = '120'] = process.argv.slice(2)
const deadline = Number(deadlineArg) * 1000
const sessionId = '00000000-0000-0000-0000-000000000001'
/** Words of the answer that only a spoken result can contain. */
const ANSWER = 'There are three files in this folder: alpha.txt, bravo.txt and charlie.txt.'
const ANSWER_WORDS = /alpha|bravo|charlie/i

function send(method, path, body) {
  const data = body === undefined ? undefined : JSON.stringify(body)
  return new Promise((resolve, reject) => {
    const req = request(
      { socketPath, method, path, headers: data ? { 'content-type': 'application/json' } : {} },
      res => {
        let text = ''
        res.on('data', chunk => (text += chunk))
        res.on('end', () => resolve({ status: res.statusCode, json: JSON.parse(text || 'null') }))
      },
    )
    req.on('error', reject)
    req.end(data)
  })
}

const t0 = Date.now()
const now = () => Math.round((Date.now() - t0) / 100) / 10
const log = (event, detail = {}) => console.log(JSON.stringify({ t: now(), event, ...detail }))

await send('POST', '/v1/join', { sessionId, title: 'Example session' })
await send('POST', '/v1/target', { sessionId })
await send('POST', '/v1/call', { action: 'start' })
log('started')

const handoffs = []
const lives = [] // the time each realtime session went live
const seen = new Set()
let waiting = null // the voice request waiting for its answer
let answeredAt = null
let spokenAt = null
let phase = 'off'
let unheard = 0
let status = null

while (Date.now() - t0 < deadline) {
  const polled = await send('GET', `/v1/next?sessionId=${sessionId}`)
  if (polled.status !== 200) {
    log('pollFailed', { status: polled.status, reply: polled.json })
    await new Promise(resolve => setTimeout(resolve, 1000))
    continue
  }
  const reply = polled.json
  status = reply.status
  if (status.call !== phase) {
    phase = status.call
    if (phase === 'live') lives.push(now())
    log('phase', { phase, ...(status.problem && { problem: status.problem }) })
  }
  if (status.unheard !== unheard) log('unheard', { count: (unheard = status.unheard) })
  for (const line of status.recentTranscript.filter(line => !seen.has(line))) {
    seen.add(line)
    log('line', { line })
    const resultIsIn = answeredAt !== null && lives.some(t => t >= answeredAt)
    if (resultIsIn && line.startsWith('Voice: ') && ANSWER_WORDS.test(line)) spokenAt ??= now()
  }
  if (reply.work?.kind === 'request') {
    handoffs.push(reply.work.brief)
    waiting = reply.work
    log('handoff', { brief: reply.work.brief })
  } else if (reply.work?.kind === 'context') {
    await send('POST', '/v1/context', { sessionId, summary: 'Example session: a scratch folder.' })
  }
  if (waiting !== null && phase === 'listening') {
    await send('POST', '/v1/answer', { sessionId, id: waiting.id, status: 'ok', text: ANSWER })
    answeredAt = now()
    waiting = null
    log('answered')
  }
  if (spokenAt !== null && phase === 'listening') break
  await new Promise(resolve => setTimeout(resolve, 1000))
}

const secondsOpen = Math.round((status?.minutesThisCall ?? 0) * 600) / 10
await send('POST', '/v1/call', { action: 'stop' })
await send('POST', '/v1/leave', { sessionId })

const checks = {
  exactlyOneHandoff: handoffs.length === 1,
  answerSpokenAfterItsResult: spokenAt !== null,
  openLessThan60s: secondsOpen < 60,
  backToListening: phase === 'listening',
}
log('verdict', { checks, handoffs, answeredAt, spokenAt, secondsOpen, lives })
process.exit(Object.values(checks).every(Boolean) ? 0 : 1)
