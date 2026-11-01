// The few Node APIs the unit tests use, declared here so that `typescript` stays the only
// development dependency (no @types/node). The mod itself runs without Node.
declare module 'node:test' {
  export function test(name: string, body: () => void | Promise<void>): void
}
declare module 'node:assert/strict' {
  const assert: {
    equal(actual: unknown, expected: unknown, message?: string): void
    deepEqual(actual: unknown, expected: unknown, message?: string): void
    ok(value: unknown, message?: string): asserts value
    match(text: string, pattern: RegExp, message?: string): void
  }
  export default assert
}
declare module 'node:fs' {
  export function readdirSync(path: string): string[]
  export function readFileSync(path: string, encoding: 'utf8'): string
}
interface ImportMeta {
  readonly dirname: string
}
