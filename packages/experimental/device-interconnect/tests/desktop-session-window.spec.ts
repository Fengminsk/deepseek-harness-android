import { describe, expect, it } from 'vitest'
import { readDesktopSessionWindow, type DesktopSessionController } from '../src/host/desktop-session-window.ts'

function controller(): DesktopSessionController {
  const events = [1, 2, 3, 4].map(seq => ({ event: { seq, type: seq === 4 ? 'assistant/message' : 'step/start' } }))
  return {
    async projections() { return { kind: 'sequenced', asOfSeq: 4, values: { turnOutline: [] } } },
    async page(request) {
      const records = events.filter(record => record.event.seq <= request.throughSeq &&
        (request.beforeSeq === undefined || record.event.seq < request.beforeSeq))
      return { records, hasMore: false }
    },
  }
}

describe('desktop Session window', () => {
  it('reads the latest page from the desktop owner', async () => {
    expect(await readDesktopSessionWindow(controller(), { sessionId: 's' })).toEqual({
      events: [1, 2, 3, 4].map(seq => ({ seq, type: seq === 4 ? 'assistant/message' : 'step/start' })),
      throughSeq: 4, firstSeq: 1, hasMore: false, turns: [],
    })
  })

  it('reads only events after the last phone cursor', async () => {
    expect(await readDesktopSessionWindow(controller(), { sessionId: 's', afterSeq: 2 })).toEqual({
      events: [{ seq: 3, type: 'step/start' }, { seq: 4, type: 'assistant/message' }],
      throughSeq: 4, firstSeq: 3, hasMore: false,
    })
  })
})
