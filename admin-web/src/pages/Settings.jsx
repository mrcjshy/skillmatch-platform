/* global __ADMIN_BUILD_DATE__ */
import { useState } from 'react';
import { Link } from 'react-router-dom';

import { changeMyPassword } from '../api.js';
import { useAuth } from '../auth-context.js';
import { PASSWORD_MIN_LENGTH, SETTINGS_COPY, checkNewPassword, passwordErrorCopy } from '../domain.js';
import { Facts, LiveNotice, PageHeader } from '../ui.jsx';

/** Injected by vite.config.js at build time; absent under tools that skip the build. */
const BUILD_DATE = typeof __ADMIN_BUILD_DATE__ === 'string' ? __ADMIN_BUILD_DATE__ : null;

/**
 * Administrator Settings (owner 2026-11-06). The same three items as the app's Admin Settings:
 * Notifications, Change password and the version.
 * - The console has no push, so Notifications points to the in-console list.
 * - The password is changed in place while signed in. There is no email link, because the app's
 *   reset link opens the phone app, not a browser. Signing in and recovering an account are
 *   unchanged: still no sign-up or reset route (D-006, RF-A).
 */
export default function Settings() {
  const { handleError } = useAuth();
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [fieldError, setFieldError] = useState(null);
  const [notice, setNotice] = useState(null);
  const [saving, setSaving] = useState(false);

  async function handleSubmit(event) {
    event.preventDefault();
    if (saving) return;
    setNotice(null);
    const problem = checkNewPassword(password, confirm);
    setFieldError(problem);
    if (problem) return;
    setSaving(true);
    try {
      await changeMyPassword(password);
      setPassword('');
      setConfirm('');
      setNotice({ tone: 'success', text: SETTINGS_COPY.passwordSaved });
    } catch (e) {
      const outcome = await handleError(e);
      if (outcome.kind === 'ended') return;
      setNotice({ tone: 'danger', text: outcome.kind === 'denied' ? outcome.message : passwordErrorCopy(e?.code) });
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <PageHeader title="Settings" />
      <LiveNotice notice={notice} />

      <section className="section" aria-labelledby="settings-notifications">
        <h2 id="settings-notifications">Notifications</h2>
        <div className="card section">
          <p className="muted">{SETTINGS_COPY.notificationsIntro}</p>
          <p>
            <Link to="/notifications" className="btn btn-secondary btn-small">Open Notifications</Link>
          </p>
        </div>
      </section>

      <section className="section" aria-labelledby="settings-password">
        <h2 id="settings-password">Change password</h2>
        <form className="card section" onSubmit={(event) => { void handleSubmit(event); }} noValidate>
          <p className="muted">{SETTINGS_COPY.passwordIntro}</p>
          <div className="field">
            <label htmlFor="new-password">New password</label>
            <input
              id="new-password"
              name="new-password"
              type="password"
              autoComplete="new-password"
              aria-describedby="new-password-help"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              disabled={saving}
            />
            <p id="new-password-help" className="muted">At least {PASSWORD_MIN_LENGTH} characters.</p>
          </div>
          <div className="field">
            <label htmlFor="confirm-password">Confirm new password</label>
            <input
              id="confirm-password"
              name="confirm-password"
              type="password"
              autoComplete="new-password"
              value={confirm}
              onChange={(event) => setConfirm(event.target.value)}
              disabled={saving}
            />
          </div>
          {fieldError ? <p className="field-error" role="alert">{fieldError}</p> : null}
          <div className="row-actions">
            <button type="submit" className="btn btn-primary" disabled={saving}>
              {saving ? 'Changing password…' : 'Change password'}
            </button>
          </div>
        </form>
      </section>

      <section className="section" aria-labelledby="settings-about">
        <h2 id="settings-about">About</h2>
        <div className="card">
          <Facts rows={[['Console', 'SkillMatch Admin'], ['Built', BUILD_DATE]]} />
        </div>
      </section>
    </>
  );
}
