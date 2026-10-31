import { useEffect, useRef, useState } from 'react';
import { BrowserRouter, Navigate, NavLink, Outlet, Route, Routes, useLocation } from 'react-router-dom';

import { AuthProvider } from './auth.jsx';
import { useAuth } from './auth-context.js';
import { IconBell, IconClients, IconClose, IconDashboard, IconFlag, IconIdCard, IconMenu, IconWorker } from './icons.jsx';
import { ConfirmDialog, Status } from './ui.jsx';
import Dashboard from './pages/Dashboard.jsx';
import Directory from './pages/Directory.jsx';
import IdReviewDetail from './pages/IdReviewDetail.jsx';
import IdReviews from './pages/IdReviews.jsx';
import Notifications from './pages/Notifications.jsx';
import ReportDetail from './pages/ReportDetail.jsx';
import Reports from './pages/Reports.jsx';
import SignIn from './pages/SignIn.jsx';
import UserDetail from './pages/UserDetail.jsx';

/**
 * Routes. There is deliberately no sign-up, password-reset or role route:
 * this console serves existing active administrators only (D-006, RF-A).
 * Anything unknown falls through to "/", which the guard protects.
 */
export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          <Route path="/sign-in" element={<SignIn />} />
          <Route element={<RequireAdmin />}>
            <Route element={<Shell />}>
              <Route index element={<Dashboard />} />
              <Route path="workers" element={<Directory key="worker" kind="worker" />} />
              <Route path="clients" element={<Directory key="client" kind="client" />} />
              <Route path="users/:kind/:userId" element={<UserDetail />} />
              <Route path="id-reviews" element={<IdReviews />} />
              <Route path="id-reviews/:userId" element={<IdReviewDetail />} />
              <Route path="reports" element={<Reports />} />
              <Route path="reports/:reportId" element={<ReportDetail />} />
              <Route path="notifications" element={<Notifications />} />
            </Route>
          </Route>
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  );
}

/** Every route except /sign-in needs a session AND a passing role check. */
function RequireAdmin() {
  const { status, retryVerify, signOutHere } = useAuth();
  const location = useLocation();

  if (status === 'signed_out') {
    return <Navigate to="/sign-in" replace state={{ from: location.pathname + location.search }} />;
  }
  if (status === 'config_error') return <Navigate to="/sign-in" replace />;
  if (status === 'unverified') {
    return (
      <main className="centered">
        <Status
          tone="error"
          action={
            <div className="row-actions">
              <button type="button" className="btn btn-primary" onClick={() => { void retryVerify(); }}>Retry</button>
              <button type="button" className="btn btn-secondary" onClick={() => { void signOutHere(); }}>Sign out</button>
            </div>
          }
        >
          We couldn&apos;t confirm your administrator access. Check your connection and try again.
        </Status>
      </main>
    );
  }
  if (status !== 'admin') {
    return (
      <main className="centered">
        <Status>Checking your access…</Status>
      </main>
    );
  }
  return <Outlet />;
}

const NAV = [
  {
    group: 'Operations',
    items: [
      ['/', 'Dashboard', IconDashboard],
      ['/workers', 'Workers', IconWorker],
      ['/clients', 'Clients', IconClients],
      ['/id-reviews', 'ID reviews', IconIdCard],
      ['/reports', 'Reports', IconFlag],
    ],
  },
  { group: 'Inbox', items: [['/notifications', 'Notifications', IconBell]] },
];

const LOGO = '/skillmatch-logo.png';

function pageLabel(pathname) {
  const items = NAV.flatMap(({ items: groupItems }) => groupItems);
  const match = items.find(([to]) => (to === '/' ? pathname === '/' : pathname.startsWith(to)));
  return match ? match[1] : 'SkillMatch Admin';
}

function Shell() {
  const { email, signOutHere, signOutEverywhere } = useAuth();
  const location = useLocation();
  const mainRef = useRef(null);
  const firstRender = useRef(true);
  const [confirmGlobal, setConfirmGlobal] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const [accountError, setAccountError] = useState(null);
  const [navOpen, setNavOpen] = useState(false);
  const menuButton = useRef(null);
  const closeButton = useRef(null);

  // The phone sheet takes focus when it opens and hands it back on Escape.
  useEffect(() => {
    if (!navOpen) return undefined;
    closeButton.current?.focus();
    const onKey = (event) => {
      if (event.key !== 'Escape') return;
      setNavOpen(false);
      menuButton.current?.focus();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [navOpen]);

  // Move focus to the new page's content on navigation (not on first load).
  useEffect(() => {
    if (firstRender.current) {
      firstRender.current = false;
      return;
    }
    mainRef.current?.focus();
  }, [location.pathname]);

  async function handleSignOut() {
    if (signingOut) return;
    setSigningOut(true);
    await signOutHere();
  }

  async function handleSignOutEverywhere() {
    setConfirmGlobal(false);
    if (signingOut) return;
    setSigningOut(true);
    setAccountError(null);
    const error = await signOutEverywhere();
    if (error) {
      setAccountError(error);
      setSigningOut(false);
    }
  }

  return (
    <div className="shell">
      <a className="skip-link" href="#main">Skip to content</a>
      <div className="topbar">
        <button
          ref={menuButton}
          type="button"
          className="btn btn-ghost btn-icon"
          aria-label="Open navigation"
          aria-expanded={navOpen}
          aria-controls="sidebar"
          onClick={() => setNavOpen(true)}
        >
          <IconMenu />
        </button>
        <img className="topbar-logo" src={LOGO} alt="" width="24" height="24" />
        <span className="topbar-title">{pageLabel(location.pathname)}</span>
      </div>
      <header id="sidebar" className="sidebar" data-open={navOpen}>
        <div className="brand">
          <img className="brand-logo" src={LOGO} alt="" width="32" height="32" />
          <span className="brand-name">SkillMatch <small>Admin · Santa Ana, Pateros</small></span>
          <button
            ref={closeButton}
            type="button"
            className="btn btn-ghost btn-icon sheet-close"
            aria-label="Close navigation"
            onClick={() => {
              setNavOpen(false);
              menuButton.current?.focus();
            }}
          >
            <IconClose />
          </button>
        </div>
        <nav aria-label="Main">
          {NAV.map(({ group, items }) => (
            <div key={group}>
              <p className="group-label">{group}</p>
              <ul className="nav">
                {items.map(([to, label, NavIcon]) => (
                  <li key={to}>
                    <NavLink to={to} end={to === '/'} className="nav-link" onClick={() => setNavOpen(false)}>
                      <NavIcon />
                      {label}
                    </NavLink>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </nav>
        <section className="account" aria-label="Account">
          <p className="account-email" title={email ?? undefined}>{email ?? 'Administrator'}</p>
          <div className="row-actions">
            <button type="button" className="btn btn-secondary btn-small" onClick={() => { void handleSignOut(); }} disabled={signingOut}>
              Sign out
            </button>
            <button type="button" className="btn btn-ghost btn-small" onClick={() => setConfirmGlobal(true)} disabled={signingOut}>
              Sign out on all devices
            </button>
          </div>
          <div role="status" aria-live="polite">
            {accountError ? <p className="notice notice-danger">{accountError}</p> : null}
          </div>
        </section>
      </header>
      <main id="main" ref={mainRef} tabIndex={-1} className="canvas">
        <Outlet key={location.pathname} />
      </main>
      <ConfirmDialog
        open={confirmGlobal}
        title="Sign out on all devices?"
        body="This ends every SkillMatch session for your account: this console in every browser, and the SkillMatch mobile app too. Use “Sign out” to leave only this browser."
        confirmLabel="Sign out everywhere"
        tone="danger"
        onConfirm={() => { void handleSignOutEverywhere(); }}
        onCancel={() => setConfirmGlobal(false)}
      />
    </div>
  );
}
