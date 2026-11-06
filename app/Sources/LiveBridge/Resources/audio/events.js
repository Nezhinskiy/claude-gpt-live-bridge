// What the line's data channel says. Pure: tested with node --test.

/** An `error` event's code and message for the app; null for anything else. */
export function lineError(text) {
  let event;
  try {
    event = JSON.parse(text);
  } catch {
    return null;
  }
  if (event?.type !== 'error') return null;
  const { message, code, type } = event.error ?? {};
  const name = code || type || '';
  return { code: name, message: message || name };
}
