import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';

import { listReports } from '../api.js';
import { useAuth } from '../auth-context.js';
import {
  REPORT_COPY, formatDateTime, formatReportCategory, formatReportStatus, isOpenReport, reportContextLabel, reportStatusTone,
} from '../domain.js';
import { Chip, PageHeader, Status } from '../ui.jsx';

function ReportGroup({ title, rows, empty }) {
  const id = `group-${title.toLowerCase()}`;
  return (
    <section className="section" aria-labelledby={id}>
      <h2 id={id}>
        {title}
        <span className="count">{rows.length === 1 ? '1 report' : `${rows.length} reports`}</span>
      </h2>
      {rows.length === 0 ? (
        <p className="muted">{empty}</p>
      ) : (
        <ul className="list">
          {rows.map((report) => {
            const category = formatReportCategory(report.category);
            const status = formatReportStatus(report.status);
            const created = formatDateTime(report.created_at);
            return (
              <li key={report.report_id}>
                <Link className="list-row" to={`/reports/${report.report_id}`} aria-label={`${category}, ${status}. View report details`}>
                  <span className="list-main">
                    <span className="list-title">{category}</span>
                    <span className="list-line">
                      {report.reported_full_name
                        ? `${reportContextLabel(report.booking_id)} · Reported: ${report.reported_full_name}`
                        : reportContextLabel(report.booking_id)}
                    </span>
                    <span className="list-line">Reporter: {report.reporter_full_name}</span>
                    {created ? <span className="list-line">{created}</span> : null}
                  </span>
                  <Chip tone={reportStatusTone(report.status)}>{status}</Chip>
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

/** list_reports, in server order, split by whether an Admin can still act on them. */
export default function Reports() {
  const { handleError } = useAuth();
  const [reports, setReports] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setReports(await listReports());
    } catch (e) {
      const outcome = await handleError(e);
      if (outcome.kind === 'ended') return;
      setError(outcome.kind === 'denied' ? outcome.message : REPORT_COPY.adminLoadFailed);
    } finally {
      setLoading(false);
    }
  }, [handleError]);

  useEffect(() => { void load(); }, [load]);

  return (
    <>
      <PageHeader title="Reports">
        <button type="button" className="btn btn-secondary btn-small" onClick={() => { void load(); }} disabled={loading}>
          {loading ? 'Refreshing…' : 'Refresh'}
        </button>
      </PageHeader>
      {loading && reports === null ? (
        <Status>Loading reports…</Status>
      ) : error ? (
        <Status tone="error" action={<button type="button" className="btn btn-secondary" onClick={() => { void load(); }}>Retry</button>}>
          {error}
        </Status>
      ) : reports.length === 0 ? (
        <Status tone="empty">{REPORT_COPY.adminEmpty}</Status>
      ) : (
        <>
          <ReportGroup title="Open" rows={reports.filter((r) => isOpenReport(r.status))} empty="No open reports." />
          <ReportGroup title="Closed" rows={reports.filter((r) => !isOpenReport(r.status))} empty="No closed reports." />
        </>
      )}
    </>
  );
}
