import assert from 'node:assert/strict'

/** Exercise the original schedule tool and owner APIs inside a built Android profile. */
export async function verifySchedule({ request, waitFor, finish, modelSteps, notices }) {
  const call = (method, input) => request('api.call', {
    namespace: 'schedule', method, args: input === undefined ? {} : { request: input },
  })
  assert.deepEqual(await call('catalog'), [])
  const sessionId = 'schedule-fixture'
  const eventOffset = notices.length
  modelSteps.push({ id: 'create-schedule', tool: 'schedule_create', args: {
    title: 'Owned schedule fixture', prompt: 'Fixture must be deleted before it is due.', after_seconds: 3600,
  } })
  await request('session.send', { sessionId, requestId: 'create-schedule', text: 'Create the fixture schedule.',
    provider: 'deepseek-official', model: 'deepseek-flash' })
  await finish(sessionId)
  await waitFor(frame => notices.indexOf(frame) >= eventOffset
    && frame.method === 'api.event' && frame.params.event === 'schedule/changed')
  const entries = await call('catalog')
  assert.equal(entries.length, 1)
  const entry = entries[0]
  assert.equal(entry.sessionId, sessionId)
  assert.equal(entry.status, 'active')
  assert.equal(entry.title, 'Owned schedule fixture')
  const expected = { id: entry.id, kind: entry.kind, title: entry.title, prompt: entry.prompt,
    afterSeconds: entry.afterSeconds, scheduledAt: entry.scheduledAt }
  try {
    const history = await call('history', { sessionId, id: entry.id, limit: 20 })
    assert.equal(history.id, entry.id)
    assert.deepEqual(history.records, [])
    const updated = await call('update', { sessionId, id: entry.id, expected, title: 'Edited fixture title' })
    assert.equal(updated.updated, true)
    assert.equal(updated.record.title, 'Edited fixture title')
    const stale = await call('update', { sessionId, id: entry.id, expected, title: 'Must not overwrite' })
    assert.equal(stale.updated, false)
    assert.equal(stale.code, 'schedule_conflict')
    assert.equal((await call('catalog'))[0].title, 'Edited fixture title')
    const events = (await request('session.read', { sessionId })).events
    assert.ok(events.some(event => event.type === 'tool/call'
      && JSON.stringify(event.data).includes('schedule_create')))
    assert.ok(events.some(event => JSON.stringify(event).includes(entry.id)))
  } finally {
    assert.deepEqual(await call('delete', { sessionId, id: entry.id }), { id: entry.id, deleted: true })
  }
  assert.deepEqual(await call('catalog'), [])
  assert.deepEqual(await call('history', { sessionId, id: entry.id, limit: 20 }),
    { id: entry.id, code: 'schedule_not_found' })
  assert.ok(notices.filter(frame => frame.method === 'api.event'
    && frame.params.event === 'schedule/changed').length >= 3)
  console.log(JSON.stringify({ originalScheduleCreateTool: true, originalScheduleCatalog: true,
    originalScheduleHistory: true, expectedRecordConflict: true, originalScheduleDelete: true,
    scheduleChangeForwarded: true, scheduleToolLogged: true, fixtureRemovedBeforeDue: true }))
}
