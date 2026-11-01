// The session's title, as the Claude Code session list shows it. Pure: the reader in
// register.tsx opens only the `*.json` records of `~/.claude/sessions` and passes them here.

/** The `name` of the registry record whose `sessionId` is this session's (ADR 0001, item e). */
export function titleFromRegistry(records: readonly unknown[], sessionId: string): string | null {
  for (const record of records) {
    if (typeof record !== 'object' || record === null) continue
    const { sessionId: id, name } = record as { sessionId?: unknown; name?: unknown }
    if (id === sessionId && typeof name === 'string' && name.trim() !== '') return name.trim()
  }
  return null
}

/** The title when the registry has none: the last component of the session's folder. */
export function fallbackTitle(root: string): string {
  return root.split('/').filter(part => part !== '').at(-1) ?? root
}
