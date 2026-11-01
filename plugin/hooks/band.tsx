// The band above the prompt: the call's phase, the voice target, unheard results, the actions
// and what is wrong, in one or two rows.
import type { EngineInterface, RenderInput } from 'claude-code'

import type { Band, BandStatus } from '../types'
import type { CallAction, CallPhase, SessionId, StatusReply } from './wire.ts'

export type BandActions = { call(action: CallAction): void; target(): void; loadContext(): void }

const PHASE: Record<CallPhase, [color: string, label: string]> = {
  off: ['inactive', 'Voice off'],
  listening: ['success', 'Listening'],
  connecting: ['warning', 'Connecting'],
  live: ['error', 'Live'],
}

/** The band's view of a poll reply, as this session sees it. */
export function bandStatus(status: StatusReply, self: SessionId): BandStatus {
  const target = status.sessions.find(row => row.isTarget)
  const { call, unheard, minutesToday, problem } = status
  return {
    call, target: target?.label ?? 'none', isTarget: target?.sessionId === self, unheard, minutesToday,
    ...(problem && { problem }),
  }
}

export function drawBand($: EngineInterface, e: RenderInput<'AbovePrompt'>, state: Band, act: BandActions) {
  const { Box, Button, Text } = $.ui.resolve(e)
  const status = state.isOffline ? undefined : state.status
  const problem = [state.isOffline ? 'LiveBridge: bridge offline.' : '', state.problem ?? status?.problem ?? '']
    .filter(part => part !== '').join(' ')
  const [color, label] = PHASE[status?.call ?? 'off']
  return (
    <Box flexDirection="column">
      {status !== undefined && (
        <Box>
          <Text color={color}>● </Text>
          <Text>{label}</Text>
          <Text dimColor>{` · target: ${status.target}${status.unheard > 0 ? ` · ${status.unheard} unheard` : ''} `}</Text>
          <Button key="call" label={status.call === 'off' ? 'Start' : 'Stop'} onPress={() => act.call(status.call === 'off' ? 'start' : 'stop')} />
          {!status.isTarget && <Button key="target" label="Make target" onPress={() => act.target()} />}
          <Button key="context" label="Load context" onPress={() => act.loadContext()} />
        </Box>
      )}
      {problem !== '' && <Text color="warning">{problem}</Text>}
      {status === undefined && problem === '' && <Text dimColor>LiveBridge: joining…</Text>}
    </Box>
  )
}
