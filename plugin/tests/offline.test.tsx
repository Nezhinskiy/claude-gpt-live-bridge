import { expect, test } from 'claude-code/testing'

import { BAND, fakeWorld, VOICEMOD } from './fake-bridge.ts'

test('offlineAppIsLaunchedOrExplained', async ($, on) => {
  const world = fakeWorld(on)
  world.isAppUp = false
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  expect((await $.command.run({ ...VOICEMOD, args: 'on' })).text).toContain('not running')

  await world.clock.advance(1000)
  expect(world.launches).toEqual([['open', '-g', '-b', 'io.github.nezhinskiy.livebridge']])
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await band.find({ type: 'Text', text: /menu bar/ }))?.text).toContain('Open LiveBridge from the menu bar')
  expect(await band.find({ type: 'Text', text: /bridge offline/ })).toBeUndefined()

  await world.clock.advance(10_000)
  expect(await band.find({ type: 'Text', text: /bridge offline/ })).toBeDefined()
  expect(world.launches).toHaveLength(1)

  world.isAppUp = true
  await world.clock.advance(1000)
  expect(world.take('join')).toHaveLength(1)
  expect(await band.find({ type: 'Text', text: /bridge offline|menu bar/ })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: /Voice off/ })).toBeDefined()
  await band.unmount()
})

test('joiningAgainOpensTheAppAgain', async ($, on) => {
  // Off, then install or quit the app, then on: the next join tries to open it afresh.
  const world = fakeWorld(on)
  world.isAppUp = false
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run({ ...VOICEMOD, args: 'on' })
  await world.clock.advance(11_000)
  const opened = world.launches.length
  await $.command.run({ ...VOICEMOD, args: 'off' })
  await $.command.run({ ...VOICEMOD, args: 'on' })
  await world.clock.advance(1000)
  expect(world.launches.length).toBeGreaterThan(opened)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /bridge offline/ })).toBeUndefined()
  await band.unmount()
})
