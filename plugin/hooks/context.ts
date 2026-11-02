// The session summary the voice model is given as context, written by the session's own model
// over its own transcript. It is sent whole: the app redacts it on arrival and then caps it, so
// a cut here could shorten a secret past what the redaction matches.
import type { EngineInterface } from 'claude-code'

/** Asks for what the app keeps (`Bridge.maxContext` in BridgeCore); the app enforces it. */
const PROMPT =
  'Summarise this session for a voice assistant that will talk with its owner about it: the ' +
  'goals, where the work stands, and the open questions. Plain sentences, no code, no file ' +
  'paths unless they matter, at most 1500 characters. Reply with the summary alone.'

/**
 * The summary, or "" when the session has nothing to summarise yet. Rejects when the model gave
 * none: the engine resolves an API error, an empty reply or an abort rather than throwing.
 */
export async function summarize($: EngineInterface): Promise<string> {
  const reply = await $.model.fork({ prompt: PROMPT })
  if (reply.isAnswered) return reply.text.trim()
  if (reply.reason === 'nothing-to-fork') return ''
  throw new Error(`the model wrote no summary (${reply.reason})`)
}
