// Debug builds only. One chunk of the call tape: 16-bit little-endian stereo PCM, as base64, the
// form a page message can carry. Pure.

const scale = (sample) => Math.max(-32768, Math.min(32767, Math.floor(sample * 32768)));

export function pcmChunk(left, right) {
  const bytes = new DataView(new ArrayBuffer(left.length * 4));
  left.forEach((sample, i) => {
    bytes.setInt16(i * 4, scale(sample), true);
    bytes.setInt16(i * 4 + 2, scale(right[i]), true);
  });
  let text = '';
  for (let i = 0; i < bytes.byteLength; i++) text += String.fromCharCode(bytes.getUint8(i));
  return btoa(text);
}
