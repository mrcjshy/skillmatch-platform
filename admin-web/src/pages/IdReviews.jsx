import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';

import { listPendingIdReviews } from '../api.js';
import { useAuth } from '../auth-context.js';
import { IDENTITY_COPY, formatDateTime, identityTypeLabel } from '../domain.js';
import { Avatar, Chip, PageHeader, Status } from '../ui.jsx';

/** Pending-ID queue (list_workers_pending_id_review), oldest submission first as the RPC returns it. */
export default function IdReviews() {
  const { handleError } = useAuth();
  const [rows, setRows] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setRows(await listPendingIdReviews());
    } catch (e) {
      const outcome = await handleError(e);
      if (outcome.kind === 'ended') return;
      setError(outcome.kind === 'denied' ? outcome.message : IDENTITY_COPY.reviewLoadFailed);
    } finally {
      setLoading(false);
    }
  }, [handleError]);

  useEffect(() => { void load(); }, [load]);

  return (
    <>
      <PageHeader title="ID reviews">
        <button type="button" className="btn btn-secondary btn-small" onClick={() => { void load(); }} disabled={loading}>
          {loading ? 'Refreshing…' : 'Refresh'}
        </button>
      </PageHeader>
      <section className="section" aria-labelledby="queue-heading">
        <h2 id="queue-heading">
          Waiting for review
          {rows && rows.length > 0 ? <span className="count">{rows.length === 1 ? '1 Worker' : `${rows.length} Workers`}</span> : null}
        </h2>
        <p className="muted">Oldest submission first. Opening a review does not change it; Approve verifies the Worker.</p>
        {loading && rows === null ? (
          <Status>Loading the ID review queue…</Status>
        ) : error ? (
          <Status tone="error" action={<button type="button" className="btn btn-secondary" onClick={() => { void load(); }}>Retry</button>}>
            {error}
          </Status>
        ) : rows.length === 0 ? (
          <Status tone="empty">No identity submissions are waiting for review.</Status>
        ) : (
          <ul className="list">
            {rows.map((worker) => {
              const submitted = formatDateTime(worker.submittedAt);
              return (
                <li key={worker.documentId}>
                  <Link className="list-row" to={`/id-reviews/${worker.userId}`} aria-label={`Review identity for ${worker.fullName}`}>
                    <Avatar name={worker.fullName} />
                    <span className="list-main">
                      <span className="list-title">{worker.fullName}</span>
                      <span className="list-line">{worker.skills.length > 0 ? worker.skills.join(', ') : 'No skills added'}</span>
                      <span className="list-line">ID type: {identityTypeLabel(worker.idType)}</span>
                      {submitted ? <span className="list-line">Submitted {submitted}</span> : null}
                    </span>
                    <Chip tone="warning">Pending review</Chip>
                  </Link>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </>
  );
}
