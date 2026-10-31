import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';

import { loadDirectory } from '../api.js';
import { useAuth } from '../auth-context.js';
import {
  availabilityLabel, directoryEmptyMessage, directoryRowStatus, formatDateTime, prepareDirectorySearch,
  workerVerificationStatus,
} from '../domain.js';
import { Avatar, Chip, PageHeader, Status } from '../ui.jsx';

function summaryLine(item, kind) {
  if (kind === 'worker' && !item.is_active) return workerVerificationStatus(item).label;
  return null;
}

function readPage(value) {
  const n = Number(value);
  return Number.isSafeInteger(n) && n >= 1 ? n : 1;
}

/** Worker or Client directory: search by name, 20 per page (get_admin_*_directory). */
export default function Directory({ kind }) {
  const { handleError } = useAuth();
  const title = kind === 'worker' ? 'Workers' : 'Clients';
  const [params, setParams] = useSearchParams();
  const search = (params.get('q') ?? '').trim();
  const page = readPage(params.get('page'));
  const [draft, setDraft] = useState(search);
  const [reload, setReload] = useState(0);
  const [state, setState] = useState({ key: null, value: null, error: null });

  const key = `${kind}|${search}|${page}|${reload}`;
  const prepared = prepareDirectorySearch(draft);
  const invalidSearch = prepareDirectorySearch(search).tooLong;

  useEffect(() => {
    if (invalidSearch) return undefined;
    let cancelled = false;
    loadDirectory(kind, search, page)
      .then((value) => { if (!cancelled) setState({ key, value, error: null }); })
      .catch(async (e) => {
        const outcome = await handleError(e);
        if (cancelled || outcome.kind === 'ended') return;
        setState({
          key, value: null,
          error: outcome.kind === 'denied' ? outcome.message : 'Unable to load the directory. Please try again.',
        });
      });
    return () => { cancelled = true; };
  }, [kind, search, page, key, invalidSearch, handleError]);

  const current = state.key === key ? state : null;
  const loading = current === null && !invalidSearch;
  const result = current?.value ?? null;
  const totalPages = result ? Math.max(1, Math.ceil(result.total_count / result.page_size)) : 1;

  function go(nextSearch, nextPage) {
    const next = new URLSearchParams();
    if (nextSearch) next.set('q', nextSearch);
    if (nextPage > 1) next.set('page', String(nextPage));
    setParams(next);
    setReload((n) => n + 1);
  }

  return (
    <>
      <PageHeader title={title} />
      <form
        className="search"
        role="search"
        onSubmit={(event) => {
          event.preventDefault();
          if (!prepared.tooLong) go(prepared.search, 1);
        }}
      >
        <div className="field">
          <label htmlFor="directory-search">Search {title} by name</label>
          <input
            id="directory-search"
            type="search"
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            aria-invalid={prepared.tooLong || undefined}
            aria-describedby={prepared.tooLong ? 'directory-search-error' : undefined}
          />
          {prepared.tooLong ? (
            <p id="directory-search-error" className="field-error">Search must be 100 characters or fewer.</p>
          ) : null}
        </div>
        <div className="row-actions">
          <button type="submit" className="btn btn-primary" disabled={prepared.tooLong}>Search</button>
          <button
            type="button"
            className="btn btn-ghost"
            disabled={!draft && !search}
            onClick={() => { setDraft(''); go('', 1); }}
          >
            Clear
          </button>
        </div>
      </form>

      {invalidSearch ? <Status tone="error">Search must be 100 characters or fewer.</Status> : null}
      {loading ? <Status>Loading {title.toLowerCase()}…</Status> : null}
      {current?.error ? (
        <Status tone="error" action={<button type="button" className="btn btn-secondary" onClick={() => setReload((n) => n + 1)}>Retry</button>}>
          {current.error}
        </Status>
      ) : null}

      {result ? (
        <>
          <p className="muted" role="status" aria-live="polite">
            {result.total_count} result{result.total_count === 1 ? '' : 's'} · Page {page} of {totalPages}
          </p>
          {result.items.length === 0 ? (
            <Status tone="empty">{directoryEmptyMessage(result, kind, search)}</Status>
          ) : (
            <div className="card table-card">
              <div className="table-wrap">
                <table className="tbl">
                  <caption>{title}</caption>
                  <thead>
                    <tr>
                      <th scope="col">Name</th>
                      <th scope="col">Status</th>
                      {kind === 'worker' ? <th scope="col" className="hide-sm">Availability</th> : null}
                      <th scope="col" className="hide-sm">Joined</th>
                    </tr>
                  </thead>
                  <tbody>
                    {result.items.map((item) => {
                      const chip = directoryRowStatus(kind, item);
                      const line = summaryLine(item, kind);
                      return (
                        <tr key={item.user_id}>
                          <td>
                            <Link className="row-link" to={`/users/${kind}/${item.user_id}`}>
                              <Avatar name={item.full_name} />
                              <span>
                                {item.full_name}
                                {line ? <span className="row-sub">{line}</span> : null}
                              </span>
                            </Link>
                          </td>
                          <td><Chip tone={chip.tone}>{chip.label}</Chip></td>
                          {kind === 'worker' ? (
                            <td className="dim hide-sm">{item.has_profile ? availabilityLabel(item.availability_status) : 'No profile'}</td>
                          ) : null}
                          <td className="dim hide-sm">{formatDateTime(item.created_at) ?? 'Not recorded'}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </div>
          )}
          {result.total_count > 0 ? (
            <nav className="pager" aria-label={`${title} pages`}>
              <button type="button" className="btn btn-secondary" disabled={page <= 1} onClick={() => go(search, page - 1)}>
                Previous
              </button>
              <button type="button" className="btn btn-secondary" disabled={page >= totalPages} onClick={() => go(search, page + 1)}>
                Next
              </button>
            </nav>
          ) : null}
        </>
      ) : null}
    </>
  );
}
