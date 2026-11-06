import { createContext, useContext } from 'react';

export const LiveContext = createContext(null);

const OFFLINE = { version: 0, unread: null, refreshUnread: async () => {} };

/** Live unread count and change counter from LiveNotificationsProvider (src/live.jsx). */
export function useLiveNotifications() {
  return useContext(LiveContext) ?? OFFLINE;
}
