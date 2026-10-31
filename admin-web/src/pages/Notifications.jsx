import { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';

import { listNotifications, markNotificationRead } from '../api.js';
import { useAuth } from '../auth-context.js';
import {
  NOTIFICATION_COPY, formatDateTime, formatNotificationLabel, isUnread, notificationHref,
} from '../domain.js';
import { LiveNotice, PageHeader, Status } from '../ui.jsx';

/**
 * The caller's own notifications (recipient-only RLS). The only write is
 * mark_my_notification_read, always followed by an authoritative re-read.
 * A report notification opens the report list, as on native Admin.
 */
export default function Notifications() {
  const { handleError } = useAuth();
  const navigate = useNavigate();
  const [rows, setRows] = useState(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  const [marking, setMarking] = useState(null);
  const [notice, setNotice] = useState(null);

  const load = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      setRows(await listNotifications());
    } catch (e) {
      const outcome = await handleError(e);
      if (outcome.kind === 'ended') return;
      setLoadError(outcome.kind === 'denied' ? outcome.message : NOTIFICATION_COPY.loadGeneric);
    } finally {
      setLoading(false);
    }
  }, [handleError]);

  useEffect(() => { void load(); }, [load]);

  const busy = loading || marking !== null;

  async function activate(row) {
    if (busy) return;
    const href = notificationHref(row.type);
    if (isUnread(row.is_read)) {
      setMarking(row.id);
      setNotice(null);
      try {
        await markNotificationRead(row.id);
        try {
          setRows(await listNotifications());
        } catch {
          setNotice({ tone: 'warning', text: NOTIFICATION_COPY.markRefreshFailed });
        }
      } catch (e) {
        const outcome = await handleError(e);
        if (outcome.kind === 'ended') return;
        setNotice({ tone: 'warning', text: outcome.kind === 'denied' ? outcome.message : NOTIFICATION_COPY.markGeneric });
        setMarking(null);
        return;
      }
      setMarking(null);
    }
    if (href) navigate(href);
  }

  return (
    <>
      <PageHeader title="Notifications">
        <button type="button" className="btn btn-secondary btn-small" onClick={() => { void load(); }} disabled={busy}>
          {loading ? 'Refreshing…' : 'Refresh'}
        </button>
      </PageHeader>
      <p className="muted">{NOTIFICATION_COPY.intro}</p>
      <LiveNotice notice={notice} />
      {loading && rows === null ? (
        <Status>{NOTIFICATION_COPY.loading}</Status>
      ) : loadError ? (
        <Status tone="error" action={<button type="button" className="btn btn-secondary" onClick={() => { void load(); }}>Retry</button>}>
          {loadError}
        </Status>
      ) : rows.length === 0 ? (
        <Status tone="empty">{NOTIFICATION_COPY.empty}</Status>
      ) : (
        <ul className="list">
          {rows.map((row) => {
            const unread = isUnread(row.is_read);
            const href = notificationHref(row.type);
            const label = formatNotificationLabel(row.type);
            const created = formatDateTime(row.created_at);
            const body = (
              <span className="list-main">
                <span className="list-title">
                  {unread ? <span className="dot" aria-hidden="true" /> : null}
                  {label}
                  {unread ? <span className="unread">{NOTIFICATION_COPY.unread}</span> : null}
                </span>
                <span className={unread ? 'list-line strong' : 'list-line'}>{row.message}</span>
                {created ? <span className="list-line">{created}</span> : null}
                {marking === row.id ? (
                  <span className="list-hint">Marking as read…</span>
                ) : unread ? (
                  <span className="list-hint">{href ? 'Mark as read and open Reports' : 'Mark as read'}</span>
                ) : href ? (
                  <span className="list-hint">Open Reports</span>
                ) : null}
              </span>
            );
            return (
              <li key={row.id}>
                {unread || href ? (
                  <button
                    type="button"
                    className={`list-row ${unread ? 'list-row-unread' : ''}`}
                    onClick={() => { void activate(row); }}
                    disabled={busy}
                    aria-busy={marking === row.id || undefined}
                  >
                    {body}
                  </button>
                ) : (
                  <div className="list-row list-row-static">{body}</div>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </>
  );
}
