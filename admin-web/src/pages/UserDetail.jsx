import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';

import { loadUserDetail } from '../api.js';
import { useAuth } from '../auth-context.js';
import {
  accountStatus, accountStatusExplanation, availabilityLabel, formatDateTime, isUuid, workerVerificationStatus,
} from '../domain.js';
import { Avatar, Chip, Facts, PageHeader, Status } from '../ui.jsx';

/** Read-only Worker/Client detail (get_admin_user_detail). No account-state control, as on native. */
export default function UserDetail() {
  const { handleError } = useAuth();
  const params = useParams();
  const kind = params.kind === 'worker' || params.kind === 'client' ? params.kind : null;
  const userId = isUuid(params.userId) ? params.userId : null;
  const [reload, setReload] = useState(0);
  const [state, setState] = useState({ key: null });
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
    return () => { cancelled = true; };
  }, [key, kind, userId, handleError]);

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

  return (
    <>
      {header}
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
        <p className="muted">
          {accountStatusExplanation(detail.is_active)} Account status is shown here for review; it is not changed from this screen.
        </p>
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
    </>
  );
}
