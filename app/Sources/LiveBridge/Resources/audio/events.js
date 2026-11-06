// What the line's data channel says. Pure: tested with node --test.

/** An `error` event's message and code as one sentence for the app; null for anything else. */
export function lineError(text) {
  let event;
  try {
    event = JSON.parse(text);
  } catch {
    return null;
  }
  if (event?.type !== 'error') return null;
  const { message, code } = event.error ?? {};
  return message && code ? `${message} (${code})` : (message ?? code ?? null);
}
