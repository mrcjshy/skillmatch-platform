import { test } from 'node:test';
import assert from 'node:assert/strict';

import { NOTIFICATION_INSERTED, notificationsTopic, subscribeToNotifications } from './live.js';

test('NTF-01: subscribes to the caller\'s own private notifications topic and cleans up', () => {
  const calls = [];
  let handler = null;
  const channel = {
    on(type, filter, callback) { calls.push(['on', type, filter]); handler = callback; return channel; },
    subscribe() { calls.push(['subscribe']); return channel; },
  };
  const client = {
    channel(name, options) { calls.push(['channel', name, options]); return channel; },
    removeChannel(c) { calls.push(['remove', c === channel]); return Promise.resolve(); },
  };
  let fired = 0;
  const stop = subscribeToNotifications(client, 'abc', () => { fired += 1; });
  assert.equal(notificationsTopic('abc'), 'user:abc:notifications');
  assert.deepEqual(calls, [
    ['channel', 'user:abc:notifications', { config: { private: true } }],
    ['on', 'broadcast', { event: NOTIFICATION_INSERTED }],
    ['subscribe'],
  ]);
  handler({ payload: { notification_id: 'n1' } });
  handler({ payload: {} });
  assert.equal(fired, 2);
  stop();
  assert.deepEqual(calls.at(-1), ['remove', true]);
});
