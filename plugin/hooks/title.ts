// The session's title, as the Claude Code session list shows it. Pure: the reader in
// register.tsx opens only the `*.json` records of `~/.claude/sessions` and passes them here.

type Record = { sessionId?: unknown; name?: unknown }
const isRecord = (value: unknown): value is Record => typeof value === 'object' && value !== null

/** Where among `records` this session's own is, named or not yet; -1 when none is. */
export function recordIndex(records: readonly unknown[], sessionId: string): number {
  return records.findIndex(record => isRecord(record) && record.sessionId === sessionId)
}

/** The `name` of the registry record whose `sessionId` is this session's (ADR 0001, item e). */
export function titleFromRegistry(records: readonly unknown[], sessionId: string): string | null {
  const record = records[recordIndex(records, sessionId)]
  const name = isRecord(record) ? record.name : undefined
  return typeof name === 'string' && name.trim() !== '' ? name.trim() : null
}

/** The title when the registry has none: the last component of the session's folder. */
export function fallbackTitle(root: string): string {
  return root.split('/').filter(part => part !== '').at(-1) ?? root
}
