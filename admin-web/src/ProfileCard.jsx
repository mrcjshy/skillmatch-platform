import { useEffect, useState } from 'react';

import { loadAccountProfile } from './api.js';
import { useAuth } from './auth-context.js';
import {
  EDUCATION_LABELS, formatBirthDate, formatHomeAddress, formatJobYears,
} from './domain.js';
import { Status } from './ui.jsx';

/** Label / value rows; unlike Facts, keys come from the index, so repeated labels are fine. */
function Rows({ rows }) {
  return (
    <dl className="facts">
      {rows.map(([label, value], index) => (
        <div key={index} className="fact">
          <dt>{label}</dt>
          <dd>{value ?? 'Not provided'}</dd>
        </div>
      ))}
    </dl>
  );
}

/**
 * REG-01: a Worker's resume or a Client's details, contact included, for Administrators
 * (get_admin_account_profile). Used on Worker/Client details and on ID review, verified or not.
 */
export function ProfileCard({ userId }) {
  const { handleError } = useAuth();
  const [attempt, setAttempt] = useState(0);
  const [state, setState] = useState({ key: null });
  const key = userId ? `${userId}|${attempt}` : null;

  useEffect(() => {
    if (!key) return undefined;
    let cancelled = false;
    loadAccountProfile(userId)
      .then((profile) => { if (!cancelled) setState({ key, profile, error: null }); })
      .catch(async (e) => {
        const outcome = await handleError(e);
        if (cancelled || outcome.kind === 'ended') return;
        setState({
          key, profile: null,
          error: outcome.kind === 'denied' ? outcome.message : 'Unable to load this profile. Please try again.',
        });
      });
    return () => { cancelled = true; };
  }, [key, userId, handleError]);

  const current = state.key === key ? state : null;
  const p = current?.profile;
  const worker = p?.role === 'worker';

  return (
    <section className="section card" aria-labelledby="profile-heading">
      <h2 id="profile-heading">{p && !worker ? 'Client details' : 'Resume'}</h2>
      {!current ? <Status>Loading profile…</Status>
        : current.error || !p ? (
          <Status
            tone="error"
            action={<button type="button" className="btn btn-secondary" onClick={() => setAttempt((n) => n + 1)}>Retry</button>}
          >
            {current.error ?? 'Profile unavailable.'}
          </Status>
        ) : (
          <>
            {p.profile_completed_at === null || (worker && p.resume_completed_at === null) ? (
              <p className="muted">
                {worker ? 'This Worker has not finished their resume yet.' : 'This Client has not finished their details yet.'}
              </p>
            ) : null}
            <Rows rows={[
              ['Full name', p.full_name],
              ...(worker ? [['Birth date', formatBirthDate(p.birth_date)]] : []),
              ['Home address', formatHomeAddress(p)],
              ['Phone', p.phone],
              ['Email', p.email],
            ]} />
            {worker ? (
              <>
                <h3 className="subhead">Education</h3>
                <Rows rows={[
                  ['Highest education', p.education_level ? EDUCATION_LABELS[p.education_level] : null],
                  ...(p.school_name ? [['School', p.school_name]] : []),
                ]} />
                <h3 className="subhead">Skills</h3>
                {p.skills.length
                  ? <ul className="skill-list">{p.skills.map((s, index) => <li key={index}>{s.name}</li>)}</ul>
                  : <p className="muted">No skills added.</p>}
                <h3 className="subhead">Work history</h3>
                {p.work_history.length
                  ? <Rows rows={p.work_history.map((j) => [formatJobYears(j), `${j.role} · ${j.employer}`])} />
                  : <p className="muted">No past jobs listed.</p>}
              </>
            ) : null}
          </>
        )}
    </section>
  );
}
