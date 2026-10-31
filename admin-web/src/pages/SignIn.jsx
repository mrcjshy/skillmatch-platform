import { useState } from 'react';
import { Navigate, useLocation } from 'react-router-dom';

import { useAuth, usePageTitle } from '../auth-context.js';
import { SkillMatchMark } from '../icons.jsx';
import { safeRedirectPath } from '../session.js';
import { configError } from '../supabase.js';

/**
 * Email + password sign-in for EXISTING administrators. No sign-up link, no
 * password reset and no role choice by design: accounts and roles are
 * managed outside this console.
 */
export default function SignIn() {
  usePageTitle('Sign in');
  const { status, notice, signIn } = useAuth();
  const location = useLocation();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState(null);
  const [submitting, setSubmitting] = useState(false);

  if (status === 'admin') return <Navigate to={safeRedirectPath(location.state?.from)} replace />;

  const busy = submitting || status === 'checking' || status === 'loading';

  async function handleSubmit(event) {
    event.preventDefault();
    if (busy || status === 'config_error') return;
    setError(null);
    if (email.trim() === '' || password === '') {
      setError('Enter your email and password.');
      return;
    }
    setSubmitting(true);
    const message = await signIn(email.trim(), password);
    setSubmitting(false);
    setPassword('');
    if (message) setError(message);
  }

  const message = error ?? notice;

  return (
    <main className="signin">
      <div className="signin-art" aria-hidden="true">
        <SkillMatchMark className="signin-mark" />
      </div>
      <div className="signin-panel">
      <div className="signin-card">
        <div className="brand">
          <img className="brand-logo" src="/skillmatch-logo.png" alt="" width="32" height="32" />
          <span className="brand-name">SkillMatch <small>Admin · Santa Ana, Pateros</small></span>
        </div>
        <h1>Sign in</h1>
        <p className="muted">For existing SkillMatch administrators.</p>

        <div role="status" aria-live="polite" aria-atomic="true">
          {status === 'config_error' ? (
            <p className="notice notice-danger">This console is not configured. {configError}</p>
          ) : message ? (
            <p className={`notice ${error ? 'notice-danger' : 'notice-warning'}`}>{message}</p>
          ) : null}
        </div>

        <form onSubmit={handleSubmit} noValidate>
          <div className="field">
            <label htmlFor="email">Email</label>
            <input
              id="email"
              name="email"
              type="email"
              autoComplete="username"
              inputMode="email"
              required
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              disabled={busy}
            />
          </div>
          <div className="field">
            <label htmlFor="password">Password</label>
            <input
              id="password"
              name="password"
              type="password"
              autoComplete="current-password"
              required
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              disabled={busy}
            />
          </div>
          <button type="submit" className="btn btn-primary btn-block" disabled={busy || status === 'config_error'}>
            {busy ? 'Signing in…' : 'Sign in'}
          </button>
        </form>
        <p className="fine-print">
          This session stays in this browser tab only and ends after 15 minutes without activity.
        </p>
      </div>
      </div>
    </main>
  );
}
