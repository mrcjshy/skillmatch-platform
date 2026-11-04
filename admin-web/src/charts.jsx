import { useEffect, useId, useLayoutEffect, useRef, useState } from 'react';

import { axisTicks, blockWidths, describePart, fitsInside, formatShare } from './chart-data.js';
import { plural } from './domain.js';

/*
 * Dashboard charts, hand-built in HTML (no chart library; the CSP forbids inline style markup, and
 * React's style prop is CSSOM, which it allows). Forms follow the dataviz method: a tall segmented
 * bar for one whole split into a few parts, a stacked bar chart for several wholes on one axis. Every
 * chart has a legend, a hover and keyboard tooltip, one tab stop with arrow keys between parts, and a
 * table view, so no value depends on colour or on hovering.
 */

const GAP = 2; // px of surface between touching blocks (admin.css .seg / .bars-bar gap)
const LABEL_FONT = '600 12px "Manrope Variable", system-ui, sans-serif';

let measureContext = null;
function textWidth(text) {
  measureContext ??= document.createElement('canvas').getContext('2d');
  measureContext.font = LABEL_FONT;
  return measureContext.measureText(text).width;
}

/** Re-render once the self-hosted font has loaded, so in-block labels are measured in Manrope. */
function useFontsReady() {
  const [ready, setReady] = useState(() => document.fonts?.status === 'loaded');
  useEffect(() => {
    let live = true;
    document.fonts?.ready.then(() => { if (live) setReady(true); });
    return () => { live = false; };
  }, []);
  return ready;
}

function useWidth(ref) {
  const [width, setWidth] = useState(0);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return undefined;
    const update = () => setWidth(node.getBoundingClientRect().width);
    update();
    const observer = new ResizeObserver(update);
    observer.observe(node);
    return () => observer.disconnect();
  }, [ref]);
  return width;
}

/** One tab stop per chart; arrow keys, Home and End move between its parts. */
function useRoving(count) {
  const [index, setIndex] = useState(0);
  const refs = useRef([]);
  const active = Math.min(index, Math.max(0, count - 1));
  const onKeyDown = (event) => {
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key];
    let next = null;
    if (step !== undefined) next = (active + step + count) % count;
    else if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = count - 1;
    if (next === null || count === 0) return;
    event.preventDefault();
    setIndex(next);
    refs.current[next]?.focus();
  };
  return { active, setIndex, refs, onKeyDown };
}

/** The value leads, the name follows; a short line key in the series colour. Visual only: parts carry their own names. */
function Tip({ tip }) {
  if (!tip) return null;
  return (
    <div className="viz-tip" aria-hidden="true" style={{ left: `${tip.x}px`, top: `${tip.y}px` }}>
      <span className={`viz-key role-${tip.role}`} />
      <span className="viz-tip-value">{tip.value}</span>
      <span className="viz-tip-label">{tip.label}</span>
    </div>
  );
}

/** Positions the tooltip over a part, kept inside the chart's own box. */
function tipFor(container, node, content) {
  const box = container.getBoundingClientRect();
  const rect = node.getBoundingClientRect();
  const half = Math.min(110, box.width / 2);
  const x = Math.min(Math.max(rect.left + rect.width / 2 - box.left, half), box.width - half);
  return { ...content, x, y: rect.top - box.top };
}

/**
 * Tall segmented bar: one whole split into parts, each a block in its status colour with its count
 * printed inside when it fits. A part at zero draws nothing.
 */
export function SegmentedBar({ split, noun, label }) {
  const root = useRef(null);
  const track = useRef(null);
  const width = useWidth(track);
  useFontsReady();
  const [tip, setTip] = useState(null);
  const visible = split.parts.filter((part) => part.value > 0);
  const widths = blockWidths(visible.map((part) => part.value), width, GAP);
  const roving = useRoving(visible.length);

  const show = (part, node) => setTip(tipFor(root.current, node, {
    role: part.role, value: plural(part.value, noun), label: `${part.label} · ${formatShare(part.share)}`,
  }));

  return (
    <div ref={root} className="viz">
      {visible.length === 0 ? (
        <div ref={track} className="seg seg-empty"><span>No {noun}s yet</span></div>
      ) : (
        <div ref={track} className="seg" role="group" aria-label={label} onKeyDown={roving.onKeyDown}>
          {visible.map((part, i) => {
            const count = part.value.toLocaleString();
            const fits = width > 0 && fitsInside(textWidth(count), widths[i]);
            return (
              <div
                key={part.key}
                ref={(node) => { roving.refs.current[i] = node; }}
                className={`seg-part role-${part.role}`}
                style={{ flexGrow: part.value }}
                role="img"
                aria-label={describePart(part, noun)}
                tabIndex={i === roving.active ? 0 : -1}
                onPointerEnter={(event) => show(part, event.currentTarget)}
                onPointerLeave={() => setTip(null)}
                onFocus={(event) => { roving.setIndex(i); show(part, event.currentTarget); }}
                onBlur={() => setTip(null)}
              >
                {fits ? <span className="seg-label" aria-hidden="true">{count}</span> : null}
              </div>
            );
          })}
        </div>
      )}
      <Tip tip={tip} />
    </div>
  );
}

/** Names in block order, each beside a swatch of its colour; the numbers live on the chart and in the table. */
export function Legend({ items }) {
  return (
    <ul className="legend">
      {items.map((item) => (
        <li key={item.key}>
          <span className={`swatch role-${item.role}`} aria-hidden="true" />
          {item.label}
        </li>
      ))}
    </ul>
  );
}

/**
 * Horizontal stacked bars on one shared count axis: one bar per row (a whole), split by series.
 * Square at the baseline, 4px rounded at the data end, total printed at the tip.
 */
export function StackedBars({ rows, series, noun, label }) {
  const root = useRef(null);
  const [tip, setTip] = useState(null);
  const ticks = axisTicks(Math.max(0, ...rows.map((row) => row.total)));
  const top = ticks.at(-1);
  const flat = rows.flatMap((row) => row.parts.filter((part) => part.value > 0).map((part) => ({ row, part })));
  const roving = useRoving(flat.length);
  let index = -1;

  const show = (row, part, node) => setTip(tipFor(root.current, node, {
    role: part.role,
    value: `${part.value.toLocaleString()} of ${plural(row.total, noun)}`,
    label: `${row.label} · ${part.label} · ${formatShare(part.share)}`,
  }));

  return (
    <div ref={root} className="viz">
      <Legend items={series} />
      <div className="bars" role="group" aria-label={label} onKeyDown={roving.onKeyDown}>
        {/* Gridlines sit behind the rows in a layer that starts after the name column. */}
        <div className="bars-grid" aria-hidden="true">
          <div className="bars-scale">
            {ticks.map((tick) => <span key={tick} className="bars-gridline" style={{ left: `${(tick / top) * 100}%` }} />)}
          </div>
        </div>
        {rows.map((row) => (
          <div key={row.key} className="bars-row">
            <span className="bars-name">{row.label}</span>
            <div className="bars-track">
              <div className="bars-scale">
                <div className="bars-bar" style={{ width: `${(row.total / top) * 100}%` }}>
                  {row.parts.filter((part) => part.value > 0).map((part) => {
                    index += 1;
                    const i = index;
                    return (
                      <div
                        key={part.key}
                        ref={(node) => { roving.refs.current[i] = node; }}
                        className={`bars-part role-${part.role}`}
                        style={{ flexGrow: part.value }}
                        role="img"
                        aria-label={`${row.label}, ${describePart(part, noun)}`}
                        tabIndex={i === roving.active ? 0 : -1}
                        onPointerEnter={(event) => show(row, part, event.currentTarget)}
                        onPointerLeave={() => setTip(null)}
                        onFocus={(event) => { roving.setIndex(i); show(row, part, event.currentTarget); }}
                        onBlur={() => setTip(null)}
                      />
                    );
                  })}
                </div>
                <span className="bars-total" style={{ left: `${(row.total / top) * 100}%` }} aria-hidden="true">
                  {row.total.toLocaleString()}
                </span>
              </div>
            </div>
          </div>
        ))}
        <div className="bars-axis" aria-hidden="true">
          <span className="bars-name" />
          <div className="bars-track">
            <div className="bars-scale">
              {ticks.map((tick) => (
                <span key={tick} className="bars-tick" style={{ left: `${(tick / top) * 100}%` }}>{tick.toLocaleString()}</span>
              ))}
            </div>
          </div>
        </div>
      </div>
      <Tip tip={tip} />
    </div>
  );
}

/** A chart in a card with its table view (the accessible twin) one click away. */
export function ChartCard({ title, meta, table, children, className = '' }) {
  const [showTable, setShowTable] = useState(false);
  const headingId = useId();
  const tableId = useId();
  return (
    <section className={`card chart-card ${className}`} aria-labelledby={headingId}>
      <div className="chart-head">
        <div className="chart-titles">
          <h2 id={headingId}>{title}</h2>
          {meta ? <p className="chart-meta">{meta}</p> : null}
        </div>
        <button
          type="button"
          className="btn btn-ghost btn-small chart-toggle"
          aria-expanded={showTable}
          aria-controls={tableId}
          onClick={() => setShowTable((open) => !open)}
        >
          {showTable ? 'Hide table' : 'Table'}
        </button>
      </div>
      {children}
      <div id={tableId} className="chart-table" hidden={!showTable}>{table}</div>
    </section>
  );
}

/** Table view of one split. */
export function SplitTable({ caption, split, head = 'Status' }) {
  return (
    <table className="tbl tbl-compact">
      <caption>{caption}</caption>
      <thead>
        <tr><th scope="col">{head}</th><th scope="col" className="num">Count</th><th scope="col" className="num">Share</th></tr>
      </thead>
      <tbody>
        {split.parts.map((part) => (
          <tr key={part.key}>
            <th scope="row"><span className={`swatch role-${part.role}`} aria-hidden="true" />{part.label}</th>
            <td className="num">{part.value.toLocaleString()}</td>
            <td className="num">{formatShare(part.share)}</td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr><th scope="row">Total</th><td className="num">{split.total.toLocaleString()}</td><td className="num">{split.total > 0 ? '100%' : '0%'}</td></tr>
      </tfoot>
    </table>
  );
}

/** Table view of several wholes split by the same series. */
export function MatrixTable({ caption, rows, series, head }) {
  return (
    <div className="table-wrap">
      <table className="tbl tbl-compact">
        <caption>{caption}</caption>
        <thead>
          <tr>
            <th scope="col">{head}</th>
            {series.map((item) => <th key={item.key} scope="col" className="num">{item.label}</th>)}
            <th scope="col" className="num">Total</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.key}>
              <th scope="row">{row.label}</th>
              {row.parts.map((part) => <td key={part.key} className="num">{part.value.toLocaleString()}</td>)}
              <td className="num">{row.total.toLocaleString()}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
