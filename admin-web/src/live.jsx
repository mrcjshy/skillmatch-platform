import { useCallback, useEffect, useMemo, useState } from 'react';

import { countUnreadNotifications, getUserId } from './api.js';
import { LiveContext } from './live-context.js';
import { subscribeToNotifications } from './live.js';
import { supabase } from './supabase.js';

/**
 * Keeps the unread count and a change counter for the signed-in Administrator (NTF-01).
 * Live updates are best effort: if the channel cannot open, pages still load when opened.
 */
export function LiveNotificationsProvider({ children }) {
  const [version, setVersion] = useState(0);
  const [unread, setUnread] = useState(null);

  const refreshUnread = useCallback(async () => {
    try {
      setUnread(await countUnreadNotifications());
    } catch {
      // Keep the last known count; the session guard handles real session problems on pages.
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    let stop = null;
    (async () => {
      await refreshUnread();
      try {
        const userId = await getUserId();
        if (cancelled || !userId) return;
        await supabase.realtime.setAuth();
        if (cancelled) return;
        stop = subscribeToNotifications(supabase, userId, () => {
          setVersion((n) => n + 1);
          void refreshUnread();
        });
      } catch {
        // No live channel; nothing else changes.
      }
    })();
    return () => {
      cancelled = true;
      stop?.();
    };
  }, [refreshUnread]);

  const value = useMemo(() => ({ version, unread, refreshUnread }), [version, unread, refreshUnread]);
  return <LiveContext.Provider value={value}>{children}</LiveContext.Provider>;
}
