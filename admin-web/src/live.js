/**
 * Live notification signal (NTF-01, owner 2026-11-06). The database's R5 trigger sends a
 * private Broadcast `notification_inserted` on `user:<id>:notifications` for every new row.
 * The message carries no content: it only says "re-read", exactly as on the native app.
 */
export const NOTIFICATION_INSERTED = 'notification_inserted';

export const notificationsTopic = (userId) => `user:${userId}:notifications`;

/** Subscribes `onInserted` to the caller's own private topic. Returns the cleanup. */
export function subscribeToNotifications(client, userId, onInserted) {
  const channel = client.channel(notificationsTopic(userId), { config: { private: true } });
  channel.on('broadcast', { event: NOTIFICATION_INSERTED }, () => onInserted());
  channel.subscribe();
  return () => {
    void client.removeChannel(channel);
  };
}
