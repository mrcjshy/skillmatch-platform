import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';

import { loadAnalytics } from '../api.js';
import { useAuth } from '../auth-context.js';
import {
  PAYMENT_SERIES, bookingSplit, describeSplit, formatShare, jobSplit, paymentRows, reportSplit, verificationSplit,
} from '../chart-data.js';
import { ChartCard, Legend, MatrixTable, SegmentedBar, SplitTable, StackedBars } from '../charts.jsx';
import { PAYMENT_METHOD_LABELS, formatDateTime, idReviewAttention, plural, reportAttention, sumBucket } from '../domain.js';
import { Chip, PageHeader, Status } from '../ui.jsx';

const methodTitle = (method) => (method === 'qrph' ? `${PAYMENT_METHOD_LABELS.qrph} (TEST)` : PAYMENT_METHOD_LABELS[method]);

function Kpi({ label, value, note }) {
  return (
    <div className="kpi">
      <dt className="kpi-label">{label}</dt>
      <dd className="kpi-value">{value.toLocaleString()}</dd>
      {note ? <dd className="kpi-note">{note}</dd> : null}
    </div>
  );
}

const share = (split, key) => formatShare(split.parts.find((part) => part.key === key).share);

/** One whole, one tall segmented bar, its legend and its table. */
function SplitChart({ title, meta, split, noun, head = 'Status' }) {
  const shown = split.parts.filter((part) => part.value > 0);
  return (
    <ChartCard title={title} meta={meta} table={<SplitTable caption={title} split={split} head={head} />}>
      <SegmentedBar split={split} noun={noun} label={describeSplit(split, noun, title)} />
      {shown.length > 0 ? <Legend items={shown} /> : null}
    </ChartCard>
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
  const bookings = summary ? bookingSplit(summary) : null;
  const jobs = summary ? jobSplit(summary) : null;
  const reports = summary ? reportSplit(summary) : null;
  const verification = summary ? verificationSplit(summary) : null;
  const payments = summary ? paymentRows(summary, methodTitle) : null;

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
            <Kpi label="Jobs" value={sumBucket(summary.jobsByStatus)} note={`${summary.jobsByStatus.open.toLocaleString()} open`} />
            <Kpi label="Bookings" value={sumBucket(summary.bookingsByStatus)} note={`${summary.completedBookings.toLocaleString()} completed`} />
            <Kpi label="Reports" value={sumBucket(summary.reportsByStatus)} note={`${plural(summary.reportsNeedingAttention, 'report')} open`} />
          </dl>
          <p className="fine-print">Current retained-data snapshot, including inactive accounts and retained test data.</p>
        </section>
      ) : loading ? (
        <Status>Loading Admin analytics…</Status>
      ) : null}

      {/* A refresh keeps the last snapshot on screen, dimmed, instead of flashing a loader. */}
      <div className={loading && summary ? 'dash is-refreshing' : 'dash'}>
        <div className="dash-top">
          <section className="card attention-card" aria-labelledby="attention-heading">
            <h2 id="attention-heading">Needs attention</h2>
            <ul className="list list-flush">
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
          {verification ? (
            <SplitChart
              title="Worker verification"
              meta={`${share(verification, 'verified')} of ${plural(verification.total, 'Worker')} verified`}
              split={verification}
              noun="Worker"
              head="Stage"
            />
          ) : null}
        </div>

        {summary ? (
          <>
            <div className="dash-charts">
              <SplitChart
                title="Bookings by status"
                meta={`${plural(bookings.total, 'booking')} · ${share(bookings, 'completed')} completed`}
                split={bookings}
                noun="booking"
              />
              <SplitChart
                title="Jobs by status"
                meta={`${plural(jobs.total, 'job')} · ${summary.jobsByStatus.open.toLocaleString()} open`}
                split={jobs}
                noun="job"
              />
              <SplitChart
                title="Reports by status"
                meta={`${plural(reports.total, 'report')} · ${summary.reportsNeedingAttention.toLocaleString()} open`}
                split={reports}
                noun="report"
              />
            </div>
            <ChartCard
              className="chart-wide"
              title="Payments by method"
              meta="Bookings by payment method and payment status. These are counts, not money: PayMongo runs in TEST mode, so no real money moves."
              table={<MatrixTable caption="Bookings by payment method and payment status" rows={payments} series={PAYMENT_SERIES} head="Method" />}
            >
              <StackedBars
                rows={payments}
                series={PAYMENT_SERIES}
                noun="booking"
                label={`Payments by method. ${plural(payments.reduce((sum, row) => sum + row.total, 0), 'booking')} in total.`}
              />
            </ChartCard>
          </>
        ) : null}
      </div>
    </>
  );
}
