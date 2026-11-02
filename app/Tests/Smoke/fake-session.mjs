// A fake Claude Code session for scripts/smoke.sh: it speaks the mod's side of the wire over the
// app's Unix socket (join, target, Start, a poll every second, one answer), records what the
// bridge reports, and checks the run. The conversation and the minutes, which no session is
// sent, it reads from the app's files beside the socket (continuity.json, usage.json).
//
//   node app/Tests/Smoke/fake-session.mjs <socket path> [deadline seconds]
//
// It answers the voice request a few seconds after taking it, while the line still waits for
// the result, so the voice must say it by itself, before the owner's next line (the small talk).
// Exit code 0 when every check passes; the timeline and the verdict go to stdout as JSON lines.
import { readFileSync } from 'node:fs'
import { request } from 'node:http'
import { dirname, join } from 'node:path'

const [socketPath, deadlineArg = '120'] = process.argv.slice(2)
const dataDir = dirname(dirname(socketPath))
const deadline = Number(deadlineArg) * 1000
const sessionId = '00000000-0000-0000-0000-000000000001'
/** Words of the answer that only a spoken result can contain. */
const ANSWER = 'There are three files in this folder: alpha.txt, bravo.txt and charlie.txt.'
const ANSWER_WORDS = /alpha|bravo|charlie/i
/** The owner's small talk, which comes long after the request. */
const SMALL_TALK = /thanks|your day/i
/** Seconds between taking the request and answering it. */
const ANSWER_AFTER = 3

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
const readJSON = name => {
  try { return JSON.parse(readFileSync(join(dataDir, name), 'utf8')) } catch { return null }
}
const SPEAKERS = { owner: 'You', voice: 'Voice', claude: 'Claude', handoff: 'Sent' }
/** The session's conversation, `Speaker: text`, as the app keeps it. */
const conversation = () =>
  (readJSON('continuity.json')?.conversations?.[sessionId]?.lines ?? [])
    .map(line => `${SPEAKERS[line.speaker]}: ${line.text}`)
/** Swift's `Date` encodes as seconds since 2001-01-01. */
const REFERENCE_DATE = Date.UTC(2001, 0, 1) / 1000
/** Seconds the realtime session was open since this run started (usage.json). */
function secondsOpen() {
  const usage = readJSON('usage.json') ?? {}
  const since = t0 / 1000 - REFERENCE_DATE
  const open = (usage.intervals ?? []).filter(i => i.start >= since).reduce((sum, i) => sum + i.end - i.start, 0)
  const current = usage.openedAt >= since ? Date.now() / 1000 - REFERENCE_DATE - usage.openedAt : 0
  return Math.round((open + current) * 10) / 10
}

await send('POST', '/v1/join', { sessionId, title: 'Example session' })
await send('POST', '/v1/target', { sessionId })
// Start launches codex, which can take longer than the 5 s a silent session is kept, so the
// session keeps polling meanwhile, as the mod does.
const starting = send('POST', '/v1/call', { action: 'start' }).then(() => log('started'))

const handoffs = []
const lives = [] // the time each realtime session went live
const seen = new Set()
let waiting = null // the voice request waiting for its answer
let takenAt = null
let answeredAt = null
let answeredInLine = false // the answer went in while the line that handed it off was still open
let spokenAt = null
let smallTalkAt = null
let phase = 'off'
let unheard = 0
let problem = null
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
  // logged on its own: a poll can see the phase change before the problem that caused it
  if ((status.problem ?? null) !== problem) {
    problem = status.problem ?? null
    log('problem', { problem })
  }
  if (status.unheard !== unheard) log('unheard', { count: (unheard = status.unheard) })
  for (const line of conversation().filter(line => !seen.has(line))) {
    seen.add(line)
    log('line', { line })
    if (line.startsWith('You: ') && SMALL_TALK.test(line)) smallTalkAt ??= now()
    if (answeredAt !== null && line.startsWith('Voice: ') && ANSWER_WORDS.test(line)) {
      spokenAt ??= now()
    }
  }
  if (reply.work?.kind === 'request') {
    handoffs.push(reply.work.brief)
    waiting = reply.work
    takenAt = now()
    log('handoff', { brief: reply.work.brief })
  } else if (reply.work?.kind === 'context') {
    await send('POST', '/v1/context', { sessionId, summary: 'Example session: a scratch folder.' })
  }
  if (waiting !== null && now() - takenAt >= ANSWER_AFTER) {
    await send('POST', '/v1/answer', { sessionId, id: waiting.id, status: 'ok', text: ANSWER })
    answeredAt = now()
    answeredInLine = phase === 'live' && lives.length === 1
    waiting = null
    log('answered', { phase })
  }
  // the line that said the answer closed, and the small talk's line opened and closed
  if (spokenAt !== null && lives.length >= 2 && phase === 'listening') break
  await new Promise(resolve => setTimeout(resolve, 1000))
}

await starting
const open = secondsOpen()
await send('POST', '/v1/call', { action: 'stop' })
await send('POST', '/v1/leave', { sessionId })

const checks = {
  exactlyOneHandoff: handoffs.length === 1,
  answeredWhileTheLineWaited: answeredInLine,
  answerSpokenBeforeTheOwnerSpokeAgain: spokenAt !== null && (smallTalkAt ?? Infinity) > spokenAt,
  lineClosedBeforeTheSmallTalk: lives.length >= 2,
  openLessThan90s: open < 90,
  backToListening: phase === 'listening',
}
log('verdict', { checks, handoffs, answeredAt, spokenAt, smallTalkAt, secondsOpen: open, lives })
process.exit(Object.values(checks).every(Boolean) ? 0 : 1)
