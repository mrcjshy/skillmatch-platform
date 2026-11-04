import { useCallback, useEffect, useRef, useState } from 'react';
import { useParams } from 'react-router-dom';

import {
  getBookingMessages, getDisciplineState, getReport, resolveWithStrike, reviewReport, sendOutcomeEmail,
} from '../api.js';
import { useAuth } from '../auth-context.js';
import {
  REPORT_COPY, REPORT_DESCRIPTION_MAX, REVIEW_LABEL, allowedReviewStatuses, formatDateTime, formatReportCategory,
  formatReportStatus, isUuid, reportContextLabel, reportStatusTone, reviewActionCopy, validateAdminResponse,
} from '../domain.js';
import { Chip, ConfirmDialog, Facts, LiveNotice, PageHeader, Status } from '../ui.jsx';

const REVIEW_CONFIRM = {
  under_review: {
    title: 'Mark this report under review?',
    body: 'The report moves to Under review. No outcome email is sent for this step.',
    tone: 'primary',
  },
  resolved: {
    title: 'Resolve this report?',
    body: 'The report is closed as Resolved with your response, and the outcome email is sent.',
    tone: 'primary',
  },
  dismissed: {
    title: 'Dismiss this report?',
    body: 'The report is closed as Dismissed with your response, and the outcome email is sent.',
    tone: 'danger',
  },
};

const SUCCESS = new Set([REPORT_COPY.reviewSaved, REPORT_COPY.strikeSaved, REPORT_COPY.emailSent]);

/**
 * Same flow as native report-details: review_report or
 * resolve_no_show_report_with_strike, then the report-outcome-email function
 * (every status, Under review included), then an authoritative re-read.
 */
export default function ReportDetail() {
  const { handleError } = useAuth();
  const params = useParams();
  const reportId = isUuid(params.reportId) ? params.reportId : null;
  const inFlight = useRef(false);

  const [detail, setDetail] = useState(null);
  const [discipline, setDiscipline] = useState(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(null);
  const [evidence, setEvidence] = useState({ state: 'idle', rows: [], error: null });
  const [response, setResponse] = useState('');
  const [acting, setActing] = useState(null); // ReviewStatus | 'strike' | 'email' | null
  const [notice, setNotice] = useState(null);
  const [reviewError, setReviewError] = useState(null);
  const [confirm, setConfirm] = useState(null); // { kind: 'review', status, response } | { kind: 'strike', response, body }

  const fetchDetail = useCallback(async () => {
    const row = await getReport(reportId);
    let nextDiscipline = null;
    try {
      nextDiscipline = await getDisciplineState(reportId);
    } catch {
      // Native tolerates this: the strike action simply stays hidden.
    }
    setDetail(row);
    setDiscipline(nextDiscipline);
    setLoadError(null);
  }, [reportId]);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      if (reportId === null) {
        setDetail(null);
        setLoadError(REPORT_COPY.unavailable);
        return;
      }
      await fetchDetail();
    } catch (e) {
      const outcome = await handleError(e);
      if (outcome.kind === 'ended') return;
      setLoadError(outcome.kind === 'denied' ? outcome.message
        : e?.code === 'SM409' ? REPORT_COPY.unavailable : REPORT_COPY.adminDetailLoadFailed);
    } finally {
      setLoading(false);
    }
  }, [reportId, fetchDetail, handleError]);

  useEffect(() => { void load(); }, [load]);

  const bookingId = detail?.booking_id ?? null;
  useEffect(() => {
    if (bookingId === null || reportId === null) return undefined;
    let cancelled = false;
    setEvidence({ state: 'loading', rows: [], error: null });
    getBookingMessages(reportId)
      .then((rows) => { if (!cancelled) setEvidence({ state: 'ready', rows, error: null }); })
      .catch(async (e) => {
        const outcome = await handleError(e);
        if (cancelled || outcome.kind === 'ended') return;
        setEvidence({
          state: 'error', rows: [],
          error: outcome.kind === 'denied' ? outcome.message : REPORT_COPY.adminDetailLoadFailed,
        });
      });
    return () => { cancelled = true; };
  }, [bookingId, reportId, handleError]);

  function validated(target) {
    const result = validateAdminResponse(target, response);
    if (!result.ok) {
      setReviewError(result.reason === 'too_long' ? REPORT_COPY.responseTooLong : REPORT_COPY.responseRequired);
      return null;
    }
    setReviewError(null);
    return result;
  }

  function askReview(status) {
    if (inFlight.current || !detail || !allowedReviewStatuses(detail.status).includes(status)) return;
    const result = validated(status);
    if (result) setConfirm({ kind: 'review', status, response: result.response });
  }

  function askStrike() {
    if (inFlight.current || discipline?.eligible !== true) return;
    const result = validated('resolved');
    if (!result) return;
    if (result.response === null) {
      setReviewError(REPORT_COPY.responseRequired);
      return;
    }
    setConfirm({
      kind: 'strike',
      response: result.response,
      body: discipline.wouldSuspend ? REPORT_COPY.strikeSuspendBody : REPORT_COPY.strikeConfirmBody,
    });
  }

  async function refreshAfter(successText) {
    try {
      await fetchDetail();
      setNotice({ tone: SUCCESS.has(successText) ? 'success' : 'warning', text: successText });
      setResponse('');
    } catch {
      setNotice({ tone: 'warning', text: REPORT_COPY.refreshFailed });
    }
  }

  async function runReview(status, adminResponse) {
    if (inFlight.current || reportId === null) return;
    inFlight.current = true;
    setActing(status);
    setReviewError(null);
    setNotice(null);
    try {
      await reviewReport(reportId, status, adminResponse);
      // Every review status emails the reporter, Under review included (owner, 2026-11-05).
      const delivered = await sendOutcomeEmail(reportId);
      await refreshAfter(delivered ? REPORT_COPY.reviewSaved : REPORT_COPY.emailFailed);
    } catch (e) {
      const outcome = await handleError(e);
      if (outcome.kind !== 'ended') setReviewError(outcome.kind === 'denied' ? outcome.message : reviewActionCopy(e));
    } finally {
      inFlight.current = false;
      setActing(null);
    }
  }

  async function runStrike(adminResponse) {
    if (inFlight.current || reportId === null || discipline?.eligible !== true) return;
    inFlight.current = true;
    setActing('strike');
    setReviewError(null);
    setNotice(null);
    try {
      await resolveWithStrike(reportId, adminResponse);
      const delivered = await sendOutcomeEmail(reportId);
      await refreshAfter(delivered ? REPORT_COPY.strikeSaved : REPORT_COPY.emailFailed);
    } catch (e) {
      const outcome = await handleError(e);
      if (outcome.kind !== 'ended') setReviewError(outcome.kind === 'denied' ? outcome.message : reviewActionCopy(e));
    } finally {
      inFlight.current = false;
      setActing(null);
    }
  }

  async function retryEmail() {
    if (inFlight.current || reportId === null) return;
    inFlight.current = true;
    setActing('email');
    setReviewError(null);
    setNotice(null);
    const delivered = await sendOutcomeEmail(reportId);
    setNotice(delivered ? { tone: 'success', text: REPORT_COPY.emailSent } : { tone: 'warning', text: REPORT_COPY.emailFailed });
    setActing(null);
    inFlight.current = false;
  }

  const header = (
    <PageHeader title="Report details" back={{ to: '/reports', label: 'Reports' }} />
  );

  if (loading && detail === null) return <>{header}<Status>Loading report…</Status></>;
  if (loadError || detail === null) {
    return (
      <>
        {header}
        <Status tone="error" action={<button type="button" className="btn btn-secondary" onClick={() => { void load(); }}>Retry</button>}>
          {loadError ?? REPORT_COPY.unavailable}
        </Status>
      </>
    );
  }

  const targets = allowedReviewStatuses(detail.status);
  const remaining = REPORT_DESCRIPTION_MAX - response.trim().length;
  const busy = acting !== null;
  const created = formatDateTime(detail.created_at);
  const reviewedAt = formatDateTime(detail.reviewed_at);

  return (
    <>
      {header}
      <LiveNotice notice={notice} />

      <div className="card object-head">
        <section className="section">
          <h2 className="detail-name">{formatReportCategory(detail.category)}</h2>
          {created ? <p className="muted">Submitted {created}</p> : null}
          {reviewedAt ? <p className="muted">Reviewed {reviewedAt}</p> : null}
        </section>
        <p className="chips"><Chip tone={reportStatusTone(detail.status)}>{formatReportStatus(detail.status)}</Chip></p>
      </div>

      <div className="detail-grid">
      <div className="detail-main">
      <section className="section card">
        <h2>Description</h2>
        <p className="prose">{detail.description}</p>
      </section>

      {detail.booking_id !== null ? (
        <section className="section card" aria-labelledby="evidence-heading">
          <h2 id="evidence-heading">{REPORT_COPY.evidenceTitle}</h2>
          {evidence.state === 'loading' || evidence.state === 'idle' ? (
            <Status>{REPORT_COPY.evidenceLoading}</Status>
          ) : evidence.state === 'error' ? (
            <Status tone="error">{evidence.error}</Status>
          ) : evidence.rows.length === 0 ? (
            <Status tone="empty">{REPORT_COPY.evidenceEmpty}</Status>
          ) : (
            <ol className="messages">
              {evidence.rows.map((row) => (
                <li key={row.message_id}>
                  <span className="message-sender">{row.sender_role === 'worker' ? 'Worker' : 'Client'}</span>
                  <p className="prose">{row.content}</p>
                  {formatDateTime(row.created_at) ? <span className="muted">{formatDateTime(row.created_at)}</span> : null}
                </li>
              ))}
            </ol>
          )}
        </section>
      ) : null}

      <section className="section card">
        <h2>Admin response</h2>
        <p className="prose">{detail.admin_response ?? REPORT_COPY.noAdminResponse}</p>
      </section>

      {targets.length > 0 ? (
        <section className="section card" aria-labelledby="review-heading">
          <h2 id="review-heading">Review</h2>
          <div className="field">
            <label htmlFor="admin-response">{REPORT_COPY.responseLabel}</label>
            <textarea
              id="admin-response"
              rows={4}
              placeholder={REPORT_COPY.responsePlaceholder}
              value={response}
              onChange={(event) => setResponse(event.target.value)}
              disabled={busy}
              aria-describedby="admin-response-count"
              aria-invalid={reviewError ? true : undefined}
            />
            <p id="admin-response-count" className={remaining < 0 ? 'field-error' : 'muted'}>
              {remaining} / {REPORT_DESCRIPTION_MAX}
            </p>
          </div>
          <div role="alert">{reviewError ? <p className="notice notice-danger">{reviewError}</p> : null}</div>
          <div className="row-actions">
            {targets.map((status) => (
              <button
                key={status}
                type="button"
                className={`btn ${status === 'resolved' ? 'btn-primary' : 'btn-secondary'}`}
                disabled={busy}
                onClick={() => askReview(status)}
              >
                {acting === status ? REPORT_COPY.reviewing : REVIEW_LABEL[status]}
              </button>
            ))}
            {discipline?.eligible === true ? (
              <button type="button" className="btn btn-danger" disabled={busy} onClick={askStrike}>
                {acting === 'strike' ? REPORT_COPY.striking : REPORT_COPY.strikeAction}
              </button>
            ) : null}
          </div>
          {discipline?.eligible === true && discipline.currentStrikeCount !== null ? (
            <p className="muted">Current no-show strikes for the reported Worker: {discipline.currentStrikeCount} of 3.</p>
          ) : null}
        </section>
      ) : null}

      </div>

      <aside className="detail-side" aria-label="Report details">
        <section className="section card">
          <h2>Context</h2>
          <Facts rows={[['Type', reportContextLabel(detail.booking_id)], ['Job', detail.job_title], ['Booking ID', detail.booking_id]]} />
        </section>
        <section className="section card">
          <h2>People</h2>
          <Facts rows={[
            ['Reporter', detail.reporter_full_name], ['Reporter ID', detail.reporter_id],
            ['Reported', detail.reported_full_name], ['Reported user ID', detail.reported_user_id],
          ]} />
        </section>
      {detail.status === 'resolved' || detail.status === 'dismissed' ? (
        <section className="section card">
          <h2>Outcome email</h2>
          <p className="muted">Send or retry the privacy-safe outcome email without changing this report review.</p>
          <div className="row-actions">
            <button type="button" className="btn btn-secondary" disabled={busy} onClick={() => { void retryEmail(); }}>
              {acting === 'email' ? REPORT_COPY.emailing : REPORT_COPY.retryEmail}
            </button>
          </div>
        </section>
      ) : null}
      </aside>
      </div>

      <ConfirmDialog
        open={confirm?.kind === 'review'}
        title={confirm?.kind === 'review' ? REVIEW_CONFIRM[confirm.status].title : ''}
        body={confirm?.kind === 'review' ? REVIEW_CONFIRM[confirm.status].body : ''}
        confirmLabel={confirm?.kind === 'review' ? REVIEW_LABEL[confirm.status] : 'Confirm'}
        tone={confirm?.kind === 'review' ? REVIEW_CONFIRM[confirm.status].tone : 'primary'}
        onConfirm={() => {
          const chosen = confirm;
          setConfirm(null);
          if (chosen?.kind === 'review') void runReview(chosen.status, chosen.response);
        }}
        onCancel={() => setConfirm(null)}
      />
      <ConfirmDialog
        open={confirm?.kind === 'strike'}
        title={REPORT_COPY.strikeConfirmTitle}
        body={confirm?.kind === 'strike' ? confirm.body : ''}
        confirmLabel={REPORT_COPY.strikeAction}
        tone="danger"
        onConfirm={() => {
          const chosen = confirm;
          setConfirm(null);
          if (chosen?.kind === 'strike') void runStrike(chosen.response);
        }}
        onCancel={() => setConfirm(null)}
      />
    </>
  );
}
