// The values the mod keeps in `$.state` for its band above the prompt. A contract stands alone
// (no imports), so it holds the band's own view of the app's status, not the wire type.

/** What the band shows of the app's last poll reply. */
export type BandStatus = {
  call: 'off' | 'listening' | 'connecting' | 'live'
  /** The voice target's label, or `none`. */
  target: string
  isTarget: boolean
  /** Results the voice has not said yet. */
  unheard: number
  minutesToday: number
  /** The app's problem sentence. */
  problem?: string
}

/** What the band draws; null while this session has not joined LiveBridge. */
export type Band = {
  isOffline: boolean
  /** The mod's own sentence (the app could not be opened). */
  problem?: string
  /** Absent until the first poll reply. */
  status?: BandStatus
  /** This session's summary on its way to the app, then for a moment after it arrived. */
  context?: 'loading' | 'sent'
}

declare module 'claude-code' {
  interface PluginState {
    livebridge: { band: Band | null }
  }
}
