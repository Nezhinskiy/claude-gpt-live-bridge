// The text a summary is written from: the session's messages as its next request carries them
// (`$.session.messages({ as: 'api' })`), without tool output, thinking or reminders, which are the
// bulk of a long session and where secrets sit, and cut to a budget the smallest window holds.

/** One message as the engine gives it; only text and tool-use blocks are read. */
export type TranscriptMessage = {
  role: 'user' | 'assistant'
  content: string | readonly { type: string; text?: string; name?: string }[]
}

/** The longest one message is kept: its start and its end. */
export const MESSAGE_CAP = 6_000
/** The first user message, the session's goal (or, after a compaction, its summary). */
export const FIRST_CAP = 4_000

const REMINDER = /<system-reminder>[\s\S]*?<\/system-reminder>/g
const SPEAKER = { user: 'User', assistant: 'Claude' } as const

/** Whether `i` falls between the two halves of a surrogate pair: a cut there would split it. */
const insidePair = (text: string, i: number) => text.charCodeAt(i) >= 0xdc00 && text.charCodeAt(i) <= 0xdfff

/**
 * `text` whole when it fits `cap`, else its start and end around a marker, at most `cap` UTF-16
 * units long (the unit the budget counts); a cut that would split a surrogate pair leaves it out.
 */
function cut(text: string, cap: number): string {
  if (text.length <= cap) return text
  const marker = (left: number) => `\n[… ${left} characters left out …]\n`
  const keep = cap - marker(text.length).length
  let start = Math.ceil(keep / 2)
  let end = text.length - (keep - start)
  if (insidePair(text, start)) start -= 1
  if (insidePair(text, end)) end += 1
  return text.slice(0, start) + marker(end - start) + text.slice(end)
}

/** A message's words: its text without reminders, a tool use as its name; '' when it has none. */
function wordsOf(message: TranscriptMessage): string {
  const blocks = typeof message.content === 'string' ? [{ type: 'text', text: message.content }] : message.content
  return blocks
    .map(block => {
      if (block.type === 'text') return (block.text ?? '').replace(REMINDER, '').trim()
      if (block.type === 'tool_use' && message.role === 'assistant') return `[used ${block.name ?? 'a tool'}]`
      return ''
    })
    .filter(words => words !== '')
    .join('\n')
}

/**
 * The transcript as text, at most `budget` characters: the first user message (at most
 * `FIRST_CAP`) for the goal, then the newest messages back until the budget is spent, with a
 * marker saying how many were left out between them. '' when no message has any text.
 */
export function transcriptText(messages: readonly TranscriptMessage[], budget = 120_000): string {
  const lines = messages.map(message => {
    const words = wordsOf(message)
    return words === '' ? '' : `${SPEAKER[message.role]}: ${cut(words, MESSAGE_CAP)}`
  })
  const first = messages.findIndex((message, i) => message.role === 'user' && lines[i] !== '')
  if (first < 0) return ''
  const goal = `${SPEAKER.user}: ${cut(wordsOf(messages[first]!), FIRST_CAP)}`
  const rest = lines.slice(first + 1).filter(line => line !== '')
  const marker = (left: number) => `[… ${left} messages left out …]`
  // Room for the marker at its longest, so whatever is kept fits with it.
  let room = budget - goal.length - marker(rest.length).length - 4
  let kept = 0
  while (kept < rest.length && rest[rest.length - 1 - kept]!.length + 2 <= room) {
    room -= rest[rest.length - 1 - kept]!.length + 2
    kept += 1
  }
  const left = rest.length - kept
  return [goal, ...(left > 0 ? [marker(left)] : []), ...rest.slice(rest.length - kept)].join('\n\n')
}
