import { useCallback, useEffect, useRef, useState } from 'react';
import { useParams } from 'react-router-dom';

import { ID_IMAGE_URL_SECONDS, approveIdentity, createIdImageUrl, getIdentityForReview, rejectIdentity } from '../api.js';
import { useAuth } from '../auth-context.js';
import {
  IDENTITY_COPY, formatDateTime, identityActionCopy, identityTypeLabel, isUuid, validateRejectionReason,
} from '../domain.js';
import { Avatar, Chip, ConfirmDialog, Facts, LiveNotice, PageHeader, Status } from '../ui.jsx';

/**
 * One pending ID: details, the ID photo through a 120-second signed URL made
 * only when this view opens (held in memory, never stored), and the decision.
 * Approval goes only through approve_worker_identity.
 */
export default function IdReviewDetail() {
  const { handleError } = useAuth();
  const params = useParams();
  const userId = isUuid(params.userId) ? params.userId : null;
  const inFlight = useRef(false);
  const imageRequest = useRef(0);
  const reviewComplete = useRef(false);

  const [worker, setWorker] = useState(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  const [image, setImage] = useState({ url: null, state: 'idle' }); // idle | loading | ready | unavailable
  const [reason, setReason] = useState('');
  const [reasonError, setReasonError] = useState(null);
  const [acting, setActing] = useState(null);
  const [submitted, setSubmitted] = useState(false);
  const [notice, setNotice] = useState(null);
  const [confirm, setConfirm] = useState(null); // 'approve' | 'reject' | null

  const loadImage = useCallback(async (storagePath) => {
    if (reviewComplete.current) return;
    const request = ++imageRequest.current;
    setImage({ url: null, state: 'loading' });
    try {
      const url = await createIdImageUrl(storagePath);
      if (request !== imageRequest.current || reviewComplete.current) return;
      setImage(url ? { url, state: 'ready' } : { url: null, state: 'unavailable' });
    } catch (e) {
      if (request !== imageRequest.current || reviewComplete.current) return;
      const outcome = await handleError(e);
      if (outcome.kind === 'ended' || request !== imageRequest.current || reviewComplete.current) return;
      setImage({ url: null, state: 'unavailable' });
    }
  }, [handleError]);

  const load = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      if (userId === null) {
        setWorker(null);
        setLoadError(IDENTITY_COPY.reviewUnavailable);
        return;
      }
      const match = await getIdentityForReview(userId);
      if (match === null) {
        setWorker(null);
        setLoadError(IDENTITY_COPY.reviewUnavailable);
        return;
      }
      setWorker(match);
      void loadImage(match.storagePath);
    } catch (e) {
      const outcome = await handleError(e);
      if (outcome.kind === 'ended') return;
      setLoadError(outcome.kind === 'denied' ? outcome.message
        : e?.code === 'SM409' ? IDENTITY_COPY.reviewUnavailable : IDENTITY_COPY.reviewLoadFailed);
    } finally {
      setLoading(false);
    }
  }, [userId, handleError, loadImage]);

  useEffect(() => {
    const pendingImages = imageRequest;
    void load();
    // Drop the signed URL when leaving the view.
    return () => {
      pendingImages.current++;
      setImage({ url: null, state: 'idle' });
    };
  }, [load]);

  async function run(action) {
    if (inFlight.current || submitted || userId === null) return;
    inFlight.current = true;
    setActing(action);
    setNotice(null);
    try {
      if (action === 'approve') await approveIdentity(userId);
      else await rejectIdentity(userId, reason);
      reviewComplete.current = true;
      imageRequest.current++;
      setSubmitted(true);
      setImage({ url: null, state: 'idle' });
      setNotice(action === 'approve'
        ? { tone: 'success', text: 'Identity approved. The Worker is now verified.' }
        : { tone: 'info', text: IDENTITY_COPY.rejectedNotice });
    } catch (e) {
      const outcome = await handleError(e);
      if (outcome.kind === 'ended') return;
      setNotice({ tone: 'warning', text: outcome.kind === 'denied' ? outcome.message : identityActionCopy(e, action) });
    } finally {
      inFlight.current = false;
      setActing(null);
    }
  }

  function askReject() {
    const invalid = validateRejectionReason(reason);
    setReasonError(invalid);
    if (invalid === null) setConfirm('reject');
  }

  const header = (
    <PageHeader title="ID review" back={{ to: '/id-reviews', label: 'ID reviews' }} />
  );

  if (loading && worker === null) return <>{header}<Status>Loading identity review…</Status></>;
  if (loadError || worker === null) {
    return (
      <>
        {header}
        <Status tone="error" action={<button type="button" className="btn btn-secondary" onClick={() => { void load(); }}>Retry</button>}>
          {loadError ?? IDENTITY_COPY.reviewUnavailable}
        </Status>
      </>
    );
  }

  const location = [worker.barangay, worker.city].filter(Boolean).join(', ');
  const submittedAt = formatDateTime(worker.submittedAt);
  const busy = acting !== null || submitted;

  return (
    <>
      {header}
      <LiveNotice notice={notice} />

      <div className="card object-head">
        <Avatar name={worker.fullName} large />
        <section className="section">
          <h2 className="detail-name">{worker.fullName}</h2>
          {submittedAt ? <p className="muted">Submitted {submittedAt}</p> : null}
        </section>
        <p className="chips">
          <Chip tone={submitted ? 'neutral' : 'warning'}>{submitted ? 'Review submitted' : 'Pending review'}</Chip>
        </p>
      </div>

      <div className="detail-grid">
      <div className="detail-main">
      <section className="section card" aria-labelledby="id-photo-heading">
        <h2 id="id-photo-heading">ID photo</h2>
        <div className="id-photo">
          {image.state === 'ready' ? (
            <img
              src={image.url}
              alt={`${worker.fullName} identity document`}
              referrerPolicy="no-referrer"
              onError={() => setImage({ url: null, state: 'unavailable' })}
            />
          ) : image.state === 'loading' ? (
            <Status>Loading ID image…</Status>
          ) : (
            <p className="muted">ID image is not available.</p>
          )}
        </div>
        {!submitted ? (
          <div className="row-actions">
            <button type="button" className="btn btn-ghost btn-small" onClick={() => { void loadImage(worker.storagePath); }} disabled={image.state === 'loading'}>
              Reload image
            </button>
          </div>
        ) : null}
        <p className="fine-print">
          The image link expires after {ID_IMAGE_URL_SECONDS / 60} minutes and is not saved by this console. It does not stop
          the image from being saved or captured, so handle it as private identity data.
        </p>
      </section>
      </div>

      <aside className="detail-side" aria-label="Review details">
      <section className="section card">
        <h2>Submitted information</h2>
        <Facts rows={[
          ['ID type', identityTypeLabel(worker.idType)],
          ['Phone', worker.phone],
          ['Location', location || null],
        ]} />
      </section>

      <section className="section card" aria-labelledby="decision-heading">
        <h2 id="decision-heading">Decision</h2>
        <p className="muted">Approve reviews the ID and verifies the Worker. Reject leaves verification unchanged.</p>
        <div className="field">
          <label htmlFor="reject-reason">Rejection reason</label>
          <textarea
            id="reject-reason"
            rows={3}
            maxLength={600}
            placeholder="Required to reject (1–500 characters)"
            value={reason}
            onChange={(event) => { setReason(event.target.value); setReasonError(null); }}
            disabled={busy}
            aria-invalid={reasonError ? true : undefined}
            aria-describedby={reasonError ? 'reject-reason-error' : undefined}
          />
          {reasonError ? <p id="reject-reason-error" className="field-error">{reasonError}</p> : null}
        </div>
        <div className="row-actions">
          <button type="button" className="btn btn-primary" disabled={busy} onClick={() => setConfirm('approve')}>
            {acting === 'approve' ? 'Working…' : submitted ? 'Review submitted' : 'Approve ID'}
          </button>
          <button type="button" className="btn btn-secondary" disabled={busy} onClick={askReject}>
            {acting === 'reject' ? 'Working…' : 'Reject ID'}
          </button>
        </div>
      </section>
      </aside>
      </div>

      <ConfirmDialog
        open={confirm === 'approve'}
        title="Approve this ID?"
        body={`This approves the ID and verifies ${worker.fullName} as a Worker.`}
        confirmLabel="Approve ID"
        onConfirm={() => { setConfirm(null); void run('approve'); }}
        onCancel={() => setConfirm(null)}
      />
      <ConfirmDialog
        open={confirm === 'reject'}
        title="Reject this ID?"
        body={(
          <>
            <p>Verification stays unchanged. The Worker can submit a new ID. Reason:</p>
            <blockquote className="quote">{reason.trim()}</blockquote>
          </>
        )}
        confirmLabel="Reject ID"
        tone="danger"
        onConfirm={() => { setConfirm(null); void run('reject'); }}
        onCancel={() => setConfirm(null)}
      />
    </>
  );
}
