// The band above the prompt: one row with the call's phase, the voice target and unheard results
// on the left and the actions on the right; what is wrong, when anything is, on a row below.
// Start talks to this session and loads its context; while the call talks to another one, "Talk
// here" moves it here.
import type { EngineInterface, RenderInput } from 'claude-code'

import type { Band, BandStatus } from '../types'
import type { CallPhase, SessionId, StatusReply } from './wire.ts'

/** `start` makes this session the target first and loads its context; `target` is "Talk here". */
export type BandActions = { start(): void; stop(): void; mute(): void; unmute(): void; target(): void }

/** What the band and `/live` say before the app's first reply. */
export const JOINING = 'LiveBridge: joining…'

const CONTEXT_NOTE = { loading: 'Loading context…', sent: 'Context sent' } as const

const PHASE: Record<CallPhase, [color: string, label: string]> = {
  off: ['inactive', 'Voice off'],
  listening: ['success', 'Listening'],
  connecting: ['warning', 'Connecting'],
  live: ['error', 'Live'],
}

/** The band's view of a poll reply, as this session sees it. */
export function bandStatus(status: StatusReply, self: SessionId): BandStatus {
  const target = status.sessions.find(row => row.isTarget)
  const { call, unheard, minutesToday, problem, isMuted } = status
  return {
    call, target: target?.label ?? 'none', isTarget: target?.sessionId === self, unheard, minutesToday,
    ...(problem && { problem }),
    ...(isMuted !== undefined && { isMuted }),
  }
}

export function drawBand($: EngineInterface, e: RenderInput<'AbovePrompt'>, state: Band, act: BandActions) {
  const { Box, Button, Text } = $.ui.resolve(e)
  // One cell on the terminal; a graphical surface's own small step between its native buttons.
  const space = e.surface === 'terminal' ? 1 : 'sm'
  const status = state.isOffline ? undefined : state.status
  const problem = state.problem ?? status?.problem
  const [color, label] = PHASE[status?.call ?? 'off']
  const unheard = status !== undefined && status.unheard > 0 ? ` · ${status.unheard} unheard` : ''
  return (
    <Box flexDirection="column">
      <Box flexDirection="row" justifyContent="space-between" alignItems="center" columnGap={space}>
        {status === undefined
          ? state.isOffline
            ? <Text color="warning" wrap="truncate-end">LiveBridge: bridge offline</Text>
            : <Text dimColor wrap="truncate-end">{JOINING}</Text>
          : (
              <Box flexDirection="row" alignItems="center" columnGap={space} flexShrink={1}>
                <Text color={color}>●</Text>
                <Text weight="semibold">{label}</Text>
                {status.isMuted === true && <Text dimColor>· muted</Text>}
                <Text dimColor wrap="truncate-end">{`target: ${status.target}${unheard}`}</Text>
                {state.context !== undefined && (
                  <Text dimColor wrap="truncate-end">{CONTEXT_NOTE[state.context]}</Text>
                )}
              </Box>
            )}
        {status !== undefined && (
          <Box flexDirection="row" alignItems="center" columnGap={space} flexShrink={0}>
            <Button
              key="call"
              variant="primary"
              label={status.call === 'off' ? 'Start' : 'Stop'}
              onPress={() => (status.call === 'off' ? act.start() : act.stop())}
            />
            {status.call !== 'off' && status.isMuted !== undefined && (
              <Button
                key="mute"
                label={status.isMuted ? 'Unmute' : 'Mute'}
                onPress={() => (status.isMuted ? act.unmute() : act.mute())}
              />
            )}
            {status.call !== 'off' && !status.isTarget && (
              <Button key="target" label="Talk here" onPress={() => act.target()} />
            )}
          </Box>
        )}
      </Box>
      {problem !== undefined && (
        <Box flexDirection="row" columnGap={space}>
          <Text color="warning">⚠</Text>
          <Text color="warning" wrap="wrap">{problem}</Text>
        </Box>
      )}
    </Box>
  )
}
