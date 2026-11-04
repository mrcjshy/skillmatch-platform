import { useEffect, useRef, useState } from 'react';
import { useParams } from 'react-router-dom';

import { loadModeration, loadUserDetail, setAccountBanned } from '../api.js';
import { useAuth } from '../auth-context.js';
import {
  MAX_STRIKES, MODERATION_COPY, MODERATION_REASON_MAX, accountStatus, accountStatusExplanation, availabilityLabel,
  formatDateTime, isUuid, moderationActionCopy, normaliseModerationReason, strikeSummary, workerVerificationStatus,
} from '../domain.js';
import { ProfileCard } from '../ProfileCard.jsx';
import { Avatar, Chip, ConfirmDialog, Facts, LiveNotice, PageHeader, Status } from '../ui.jsx';

/**
 * Worker/Client detail (get_admin_user_detail) with MOD-01 moderation (get_admin_account_moderation):
 * no-show strikes N of 3 for Workers, the latest ban/reinstatement and one action. A ban lasts until
 * an Administrator reinstates the account; reinstating a Worker resets their strikes to 0.
 */
export default function UserDetail() {
  const { handleError } = useAuth();
  const params = useParams();
  const kind = params.kind === 'worker' || params.kind === 'client' ? params.kind : null;
  const userId = isUuid(params.userId) ? params.userId : null;
  const [reload, setReload] = useState(0);
  const [state, setState] = useState({ key: null });
  const [moderation, setModeration] = useState({ key: null });
  const [notice, setNotice] = useState(null);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);
  const inFlight = useRef(false);
  const key = kind && userId ? `${kind}|${userId}|${reload}` : null;
  const title = kind === 'worker' ? 'Worker details' : kind === 'client' ? 'Client details' : 'Account details';

  useEffect(() => {
    if (!key) return undefined;
    let cancelled = false;
    loadUserDetail(kind, userId)
      .then((detail) => { if (!cancelled) setState({ key, detail, error: null }); })
      .catch(async (e) => {
        const outcome = await handleError(e);
        if (cancelled || outcome.kind === 'ended') return;
        setState({
          key, detail: null, denied: outcome.kind === 'denied',
          error: outcome.kind === 'denied' ? outcome.message : 'Unable to load user details. Please try again.',
        });
      });
    loadModeration(userId)
      .then((data) => { if (!cancelled) setModeration({ key, data, error: null }); })
      .catch(async (e) => {
        const outcome = await handleError(e);
        if (cancelled || outcome.kind === 'ended') return;
        setModeration({ key, data: null, error: outcome.kind === 'denied' ? outcome.message : MODERATION_COPY.loadFailed });
      });
    return () => { cancelled = true; };
  }, [key, kind, userId, handleError]);

  const mod = moderation.key === key ? moderation : null;
  const banning = mod?.data?.is_active === true;

  async function submit() {
    if (inFlight.current || !mod?.data) return;
    if (normaliseModerationReason(reason) === null) {
      setSaveError(MODERATION_COPY.reasonRequired);
      return;
    }
    inFlight.current = true;
    setSaving(true);
    setSaveError(null);
    try {
      const result = await setAccountBanned(userId, banning, reason);
      setDialogOpen(false);
      setReason('');
      setNotice({
        tone: 'success',
        text: !result.changed ? MODERATION_COPY.unchanged
          : banning ? MODERATION_COPY.banned
            : kind === 'worker' ? MODERATION_COPY.reinstatedWorker : MODERATION_COPY.reinstated,
      });
      setReload((n) => n + 1);
    } catch (e) {
      const outcome = await handleError(e);
      if (outcome.kind !== 'ended') setSaveError(outcome.kind === 'denied' ? outcome.message : moderationActionCopy(e));
    } finally {
      inFlight.current = false;
      setSaving(false);
    }
  }

  function closeDialog() {
    if (saving) return;
    setDialogOpen(false);
    setSaveError(null);
  }

  const back = kind === 'client' ? { to: '/clients', label: 'Clients' } : { to: '/workers', label: 'Workers' };
  const header = <PageHeader title={title} back={back} />;

  if (!key) return <>{header}<Status tone="empty">Account unavailable.</Status></>;
  const current = state.key === key ? state : null;
  if (!current) return <>{header}<Status>Loading user details…</Status></>;
  if (current.error) {
    return (
      <>
        {header}
        <Status
          tone="error"
          action={current.denied ? null : <button type="button" className="btn btn-secondary" onClick={() => setReload((n) => n + 1)}>Retry</button>}
        >
          {current.error}
        </Status>
      </>
    );
  }
  const detail = current.detail;
  if (!detail) return <>{header}<Status tone="empty">Account unavailable.</Status></>;

  const worker = kind === 'worker' ? detail : null;
  const status = accountStatus(detail.is_active);
  const verification = worker ? workerVerificationStatus(worker) : null;

  const remaining = MODERATION_REASON_MAX - reason.trim().length;
  const lastAt = mod?.data?.last_action_at ? formatDateTime(mod.data.last_action_at) : null;

  return (
    <>
      {header}
      <LiveNotice notice={notice} />
      <div className="card object-head">
        <Avatar name={detail.full_name} large />
        <section className="section">
          <h2 className="detail-name">{detail.full_name}</h2>
          <p className="muted">{worker ? 'Worker account' : 'Client account'}</p>
        </section>
        <p className="chips">
          <Chip tone={status.tone}>{status.label}</Chip>
          {verification && detail.is_active ? <Chip tone={verification.tone}>{verification.label}</Chip> : null}
        </p>
      </div>
      <div className="grid">
      <section className="section card">
        <h2>Account</h2>
        <Facts rows={[['Account status', status.label], ['Joined', formatDateTime(detail.created_at) ?? 'Not recorded']]} />
        <p className="muted">{accountStatusExplanation(detail.is_active)}</p>
      </section>
      <ProfileCard userId={userId} />
      <section className="section card" aria-labelledby="moderation-heading">
        <h2 id="moderation-heading">Moderation</h2>
        {!mod ? <Status>Loading moderation…</Status>
          : mod.error ? (
            <Status tone="error" action={<button type="button" className="btn btn-secondary" onClick={() => setReload((n) => n + 1)}>Retry</button>}>
              {mod.error}
            </Status>
          ) : (
            <>
              {worker ? (
                <div className="strike-meter" role="img" aria-label={`No-show strikes: ${strikeSummary(mod.data.strike_count)}`}>
                  <span className="strike-label">No-show strikes</span>
                  <strong>{strikeSummary(mod.data.strike_count)}</strong>
                  {mod.data.strike_count !== null ? (
                    <span className="strike-pips" aria-hidden="true">
                      {Array.from({ length: MAX_STRIKES }, (_, i) => (
                        <span key={i} className={i < mod.data.strike_count ? 'strike-pip on' : 'strike-pip'} />
                      ))}
                    </span>
                  ) : null}
                </div>
              ) : null}
              <Facts rows={[
                ['Last action', mod.data.last_action === null ? 'None'
                  : `${mod.data.last_action === 'ban' ? 'Banned' : 'Reinstated'}${lastAt ? ` · ${lastAt}` : ''}`],
                ...(mod.data.last_reason ? [['Reason', mod.data.last_reason]] : []),
              ]} />
              <p className="muted">
                {banning
                  ? worker
                    ? `A Worker is suspended automatically at ${MAX_STRIKES} no-show strikes. A ban suspends the account now, until it is reinstated.`
                    : 'A ban suspends the account now, until it is reinstated.'
                  : worker
                    ? 'This account is suspended. Reinstating it restores access and resets no-show strikes to 0.'
                    : 'This account is suspended. Reinstating it restores access.'}
              </p>
              <div className="row-actions">
                <button type="button" className={`btn ${banning ? 'btn-danger' : 'btn-primary'}`}
                  onClick={() => { setSaveError(null); setDialogOpen(true); }}>
                  {banning ? 'Ban account' : 'Reinstate account'}
                </button>
              </div>
            </>
          )}
      </section>
      {worker ? (
        <section className="section card">
          <h2>Verification</h2>
          <Facts rows={[
            ['Worker profile', worker.has_profile ? 'Profile present' : 'No profile'],
            ['Verification', workerVerificationStatus(worker).label],
            ['Availability', worker.has_profile ? availabilityLabel(worker.availability_status) : 'No profile'],
          ]} />
        </section>
      ) : null}
      <section className="section card">
        <h2>Activity</h2>
        <Facts rows={[worker
          ? ['Completed bookings', String(worker.completed_bookings_count)]
          : ['Jobs posted', String(detail.posted_jobs_count)]]} />
        <p className="muted">Counts are based on retained records, with no date filter.</p>
      </section>
      </div>
      <ConfirmDialog
        open={dialogOpen}
        title={banning ? 'Ban this account?' : 'Reinstate this account?'}
        body={banning
          ? 'The account is suspended until an Administrator reinstates it. The user is notified with your reason.'
          : worker ? 'The account is restored and no-show strikes reset to 0. The user is notified.'
            : 'The account is restored. The user is notified.'}
        confirmLabel={saving ? (banning ? 'Banning…' : 'Reinstating…') : banning ? 'Ban account' : 'Reinstate account'}
        tone={banning ? 'danger' : 'primary'}
        onConfirm={() => { void submit(); }}
        onCancel={closeDialog}
      >
        <div className="field">
          <label htmlFor="moderation-reason">Reason</label>
          <textarea
            id="moderation-reason"
            rows={3}
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            disabled={saving}
            placeholder={banning ? 'Why is this account banned?' : 'Why is this account reinstated?'}
            aria-describedby="moderation-reason-count"
            aria-invalid={saveError ? true : undefined}
          />
          <p id="moderation-reason-count" className={remaining < 0 ? 'field-error' : 'muted'}>{remaining} characters left</p>
          <div role="alert">{saveError ? <p className="notice notice-danger">{saveError}</p> : null}</div>
        </div>
      </ConfirmDialog>
    </>
  );
}
