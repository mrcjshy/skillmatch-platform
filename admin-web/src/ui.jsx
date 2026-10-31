import { useEffect, useId, useRef } from 'react';
import { Link } from 'react-router-dom';

import { usePageTitle } from './auth-context.js';
import { IconBack } from './icons.jsx';

export function PageHeader({ title, back, children }) {
  usePageTitle(title);
  return (
    <header className="page-header">
      <div>
        {back ? (
          <Link to={back.to} className="crumb">
            <IconBack />
            Back to {back.label}
          </Link>
        ) : null}
        <h1>{title}</h1>
      </div>
      {children}
    </header>
  );
}

export function Avatar({ name, large = false }) {
  const initials = (name ?? '')
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((word) => word.charAt(0))
    .join('')
    .toUpperCase();
  return <span className={large ? 'avatar avatar-large' : 'avatar'} aria-hidden="true">{initials}</span>;
}

/** Loading / empty / error / notice states. Always announced politely. */
export function Status({ tone = 'info', children, action }) {
  const role = tone === 'error' ? 'alert' : 'status';
  return (
    <div className={`status status-${tone}`} role={role} aria-live={tone === 'error' ? 'assertive' : 'polite'}>
      <p>{children}</p>
      {action ?? null}
    </div>
  );
}

/** A live region that exists before its message does, so screen readers announce changes. */
export function LiveNotice({ notice }) {
  return (
    <div className="live-notice" role="status" aria-live="polite" aria-atomic="true">
      {notice ? <p className={`notice notice-${notice.tone}`}>{notice.text}</p> : null}
    </div>
  );
}

export function Chip({ tone = 'neutral', children }) {
  return <span className={`chip chip-${tone}`}>{children}</span>;
}

export function Facts({ rows }) {
  return (
    <dl className="facts">
      {rows.map(([label, value]) => (
        <div key={label} className="fact">
          <dt>{label}</dt>
          <dd>{value ?? 'Not provided'}</dd>
        </div>
      ))}
    </dl>
  );
}

/**
 * Modal confirmation on the native <dialog> element: focus moves into it,
 * Tab stays inside, Escape cancels, and focus returns to the opener on close.
 * Cancel is first so it receives initial focus.
 */
export function ConfirmDialog({ open, title, body, confirmLabel, tone = 'primary', onConfirm, onCancel, children }) {
  const ref = useRef(null);
  const titleId = useId();
  const bodyId = useId();

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);

  return (
    <dialog
      ref={ref}
      className="dialog"
      aria-labelledby={titleId}
      aria-describedby={bodyId}
      onCancel={(event) => {
        event.preventDefault();
        onCancel();
      }}
    >
      <h2 id={titleId}>{title}</h2>
      <div id={bodyId} className="dialog-body">
        {typeof body === 'string' ? <p>{body}</p> : body}
      </div>
      {children}
      <div className="dialog-actions">
        <button type="button" className="btn btn-secondary" onClick={onCancel}>Cancel</button>
        <button type="button" className={`btn btn-${tone}`} onClick={onConfirm}>{confirmLabel}</button>
      </div>
    </dialog>
  );
}
