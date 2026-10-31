import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';

import { loadAnalytics } from '../api.js';
import { useAuth } from '../auth-context.js';
import {
  BOOKING_KEYS, BOOKING_LABELS, JOB_KEYS, JOB_LABELS, PAYMENT_METHOD_KEYS, PAYMENT_METHOD_LABELS,
  PAYMENT_STATUS_KEYS, PAYMENT_STATUS_LABELS, REPORT_KEYS, REPORT_LABELS,
  formatDateTime, idReviewAttention, plural, reportAttention, sumBucket,
} from '../domain.js';
import { Chip, PageHeader, Status } from '../ui.jsx';

const methodTitle = (method) =>
  method === 'qrph' ? `${PAYMENT_METHOD_LABELS.qrph} (PayMongo TEST)` : PAYMENT_METHOD_LABELS[method];

const statusLine = (bucket) =>
  PAYMENT_STATUS_KEYS.map((key) => `${PAYMENT_STATUS_LABELS[key]} ${bucket[key].toLocaleString()}`).join(' · ');

function CountTable({ caption, rows }) {
  const largest = Math.max(1, ...rows.map(([, value]) => value));
  return (
    <table className="counts">
      <caption>{caption}</caption>
      <tbody>
        {rows.map(([label, value, detail]) => (
          <tr key={label}>
            <th scope="row">
              {label}
              {detail ? <span className="row-detail">{detail}</span> : null}
            </th>
            <td className="count-bar" aria-hidden="true">
              {value > 0 ? <i style={{ width: `${(value / largest) * 100}%` }} /> : null}
            </td>
            <td>{value.toLocaleString()}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function Kpi({ label, value, note }) {
  return (
    <div className="kpi">
      <dt className="kpi-label">{label}</dt>
      <dd className="kpi-value">{value.toLocaleString()}</dd>
      {note ? <dd className="kpi-note">{note}</dd> : null}
    </div>
  );
}

/** Every number comes from the one get_admin_analytics_summary read, as on native Admin Home. */
export default function Dashboard() {
  const { handleError } = useAuth();
  const [summary, setSummary] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setSummary(await loadAnalytics());
    } catch (e) {
      const outcome = await handleError(e);
      if (outcome.kind === 'ended') return;
      setError(outcome.kind === 'denied' ? outcome.message : 'Unable to load Admin analytics. Please try again.');
    } finally {
      setLoading(false);
    }
  }, [handleError]);

  useEffect(() => { void load(); }, [load]);

  const pending = summary?.pendingWorkerVerifications ?? 0;
  const open = summary?.reportsNeedingAttention ?? 0;

  return (
    <>
      <PageHeader title="Dashboard">
        <button type="button" className="btn btn-secondary btn-small" onClick={() => { void load(); }} disabled={loading}>
          {loading ? 'Refreshing…' : 'Refresh'}
        </button>
      </PageHeader>

      {error ? (
        <Status tone="error" action={<button type="button" className="btn btn-secondary" onClick={() => { void load(); }}>Retry</button>}>
          {summary ? `${error} Showing the previous snapshot.` : error}
        </Status>
      ) : null}

      {summary ? (
        <section className="section" aria-labelledby="summary-heading">
          <div className="section-head">
            <h2 id="summary-heading">Platform summary</h2>
            <p className="meta">Updated {formatDateTime(summary.asOf)}</p>
          </div>
          <dl className="kpis">
            <Kpi label="Workers" value={summary.totalWorkers} note={`${summary.verifiedWorkers.toLocaleString()} verified`} />
            <Kpi label="Clients" value={summary.totalClients} />
            <Kpi label="Jobs" value={sumBucket(summary.jobsByStatus)} />
            <Kpi label="Bookings" value={sumBucket(summary.bookingsByStatus)} note={`${summary.completedBookings.toLocaleString()} completed`} />
            <Kpi label="Reports" value={sumBucket(summary.reportsByStatus)} note={`${plural(summary.reportsNeedingAttention, 'report')} open`} />
          </dl>
          <p className="fine-print">Current retained-data snapshot, including inactive accounts and retained test data.</p>
        </section>
      ) : loading ? (
        <Status>Loading Admin analytics…</Status>
      ) : null}

      <div className="overview">
        <div className="overview-main">
      <section className="section" aria-labelledby="attention-heading">
        <h2 id="attention-heading">Needs attention</h2>
        <ul className="list">
          <li>
            <Link className="list-row" to="/id-reviews">
              <span className={pending > 0 ? 'attn-mark attn-mark-warning' : 'attn-mark'} />
              <span className="list-main">
                <span className="list-title">ID reviews</span>
                <span className="list-line">{idReviewAttention(summary)}</span>
              </span>
              {pending > 0 ? <Chip tone="warning">{pending.toLocaleString()} waiting</Chip> : null}
            </Link>
          </li>
          <li>
            <Link className="list-row" to="/reports">
              <span className={open > 0 ? 'attn-mark attn-mark-warning' : 'attn-mark'} />
              <span className="list-main">
                <span className="list-title">Reports</span>
                <span className="list-line">{reportAttention(summary)}</span>
              </span>
              {open > 0 ? <Chip tone="warning">{open.toLocaleString()} open</Chip> : null}
            </Link>
          </li>
        </ul>
        <p className="fine-print">Opening a list does not complete a review.</p>
      </section>
          {summary ? (
            <div className="pair">
              <section className="section card">
                <h2>Bookings by status</h2>
                <CountTable caption="Bookings by status" rows={BOOKING_KEYS.map((k) => [BOOKING_LABELS[k], summary.bookingsByStatus[k]])} />
              </section>
              <section className="section card">
                <h2>Jobs by status</h2>
                <CountTable caption="Jobs by status" rows={JOB_KEYS.map((k) => [JOB_LABELS[k], summary.jobsByStatus[k]])} />
              </section>
            </div>
          ) : null}
        </div>
        {summary ? (
          <aside className="rail" aria-label="More counts">
            <section className="section card">
              <h2>Reports by status</h2>
              <p className="fine-print">{plural(summary.reportsNeedingAttention, 'report')} open</p>
              <CountTable caption="Reports by status" rows={REPORT_KEYS.map((k) => [REPORT_LABELS[k], summary.reportsByStatus[k]])} />
            </section>
            <section className="section card">
              <h2>Payments</h2>
              <p className="fine-print">
                Counts of Bookings by payment method, not money. PayMongo runs in TEST mode, so no real money
                moves.
              </p>
              <CountTable caption="Bookings by payment method" rows={PAYMENT_METHOD_KEYS.map((m) => [
                methodTitle(m), sumBucket(summary.paymentsByMethodStatus[m]), statusLine(summary.paymentsByMethodStatus[m]),
              ])} />
            </section>
          </aside>
        ) : null}
      </div>
    </>
  );
}
