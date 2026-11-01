// The session summary the voice model is given as context, written by the session's own model
// over its own transcript (the app redacts it on arrival).
import type { EngineInterface } from 'claude-code'

export const CONTEXT_LIMIT = 1500

const PROMPT =
  'Summarise this session for a voice assistant that will talk with its owner about it: the ' +
  'goals, where the work stands, and the open questions. Plain sentences, no code, no file ' +
  `paths unless they matter, at most ${CONTEXT_LIMIT} characters. Reply with the summary alone.`

/** The summary, or "" when there is nothing to summarise yet or the model gave no answer. */
export async function summarize($: EngineInterface): Promise<string> {
  const reply = await $.model.fork({ prompt: PROMPT })
  return reply.isAnswered ? reply.text.trim().slice(0, CONTEXT_LIMIT) : ''
}
