import { useLayoutEffect, useMemo, useRef, useState } from 'react'
import gsap from 'gsap'
import { Flip } from 'gsap/Flip'
import { RotateCcw } from 'lucide-react'
import { eligibilityRules, matchWorkers } from '../../content/matching'
import { sampleJobs, sampleWorkers, tryMatch } from '../../content/website'
import Mark from './Mark'

gsap.registerPlugin(Flip)

const prefersReducedMotion = () =>
  window.matchMedia('(prefers-reduced-motion: reduce)').matches

const formatPoints = (points) => points.toFixed(1)

function ratingLabel(worker) {
  return worker.rating === null ? tryMatch.newWorker : `Rated ${worker.rating}`
}

function Gates({ result, job }) {
  const failedIndex = eligibilityRules.findIndex(
    (rule) => rule.id === result.failedRule?.id,
  )
  return (
    <ol className="try-gates" aria-label="Eligibility checks">
      {eligibilityRules.map((rule, index) => {
        const checked = failedIndex === -1 || index <= failedIndex
        const passed = checked && rule.passes(result.worker, job)
        const state = passed ? 'pass' : checked ? 'fail' : 'unchecked'
        return (
          <li key={rule.id} className={`try-gate try-gate-${state}`}>
            {rule.label}
            <span className="sr-only">
              {passed ? ': passed' : checked ? ': failed' : ': not checked'}
            </span>
          </li>
        )
      })}
    </ol>
  )
}

function WorkerRow({ result, job, accepted, onAccept }) {
  const { worker, score, eligible, failedRule } = result
  const isAccepted = accepted === worker.id
  const isTaken = accepted && !isAccepted && eligible
  const stateClass = !eligible
    ? 'try-row-out'
    : isAccepted
      ? 'try-row-booked'
      : isTaken
        ? 'try-row-taken'
        : ''
  return (
    <li className={`try-row ${stateClass}`} data-flip-id={worker.id} data-ui>
      <div className="try-who">
        <h4>{worker.name}</h4>
        <p>
          {worker.barangay}, {worker.city} · {ratingLabel(worker)}
        </p>
        <ul className="try-skills" aria-label={`${worker.name}'s skills`}>
          {worker.skills.map((skill) => (
            <li
              key={skill}
              className={job.skills.includes(skill) ? 'try-skill-hit' : ''}
            >
              {skill}
            </li>
          ))}
        </ul>
      </div>
      <div className="try-outcome">
        {eligible ? (
          <>
            <p className="try-score">
              <span className="sr-only">{tryMatch.scoreLabel}: </span>
              <span data-score={score.total}>{formatPoints(score.total)}</span>
              <span className="try-score-of">/100</span>
            </p>
            <p className="try-parts">
              Skill {formatPoints(score.skill)} · Location{' '}
              {formatPoints(score.location)} · Rating{' '}
              {formatPoints(score.rating)}
            </p>
            {isAccepted ? (
              <p className="try-tag try-tag-booked">{tryMatch.confirmed}</p>
            ) : isTaken ? (
              <p className="try-tag">{tryMatch.taken}</p>
            ) : (
              <button
                type="button"
                className="button button-small"
                onClick={() => onAccept(worker.id)}
              >
                {tryMatch.acceptPrefix} {worker.name}
              </button>
            )}
          </>
        ) : (
          <p className="try-reason">{failedRule.failure}</p>
        )}
      </div>
      <Gates result={result} job={job} />
    </li>
  )
}

export default function TryMatch() {
  const [jobId, setJobId] = useState(sampleJobs[0].id)
  const [accepted, setAccepted] = useState(null)
  const section = useRef(null)
  const flipState = useRef(null)
  const job = sampleJobs.find((item) => item.id === jobId)
  const results = useMemo(() => matchWorkers(sampleWorkers, job), [job])
  const eligible = results.filter((result) => result.eligible)
  const winner = results.find((result) => result.worker.id === accepted)
  const wonFromBehind = winner && eligible[0].worker.id !== accepted

  function captureRows() {
    if (prefersReducedMotion()) return
    flipState.current = Flip.getState(
      section.current.querySelectorAll('.try-row'),
    )
  }
  function chooseJob(id) {
    captureRows()
    setJobId(id)
    setAccepted(null)
  }
  function accept(id) {
    captureRows()
    setAccepted(id)
  }
  function reset() {
    captureRows()
    setAccepted(null)
  }

  useLayoutEffect(() => {
    const state = flipState.current
    flipState.current = null
    if (prefersReducedMotion()) return
    const root = section.current
    const scoreElements = () => root.querySelectorAll('[data-score]')
    // Counters stay outside the context: reverting a tween rewinds it to its
    // start, which would leave a false score on screen.
    const counters = []
    const context = gsap.context(() => {
      if (state)
        Flip.from(state, {
          duration: 0.55,
          ease: 'expo.out',
          stagger: 0.03,
          absolute: false,
        })
      if (accepted) {
        gsap.fromTo(
          '.try-result .mark-worker',
          { x: 150, y: -70 },
          { x: 0, y: 0, duration: 0.7, ease: 'expo.out' },
        )
        gsap.fromTo(
          '.try-result .mark-client',
          { x: -150, y: 70 },
          { x: 0, y: 0, duration: 0.7, ease: 'expo.out' },
        )
      }
    }, section)
    if (!accepted && state)
      scoreElements().forEach((element) => {
        const total = Number(element.dataset.score)
        const counter = { value: Math.max(0, total - 22) }
        counters.push(
          gsap.to(counter, {
            value: total,
            duration: 0.6,
            ease: 'expo.out',
            onUpdate: () => {
              element.textContent = formatPoints(counter.value)
            },
          }),
        )
      })
    return () => {
      counters.forEach((counter) => counter.kill())
      context.revert()
      scoreElements().forEach((element) => {
        element.textContent = formatPoints(Number(element.dataset.score))
      })
    }
  }, [jobId, accepted])

  return (
    <section
      id="try"
      className="try section-pad"
      aria-labelledby="try-title"
      ref={section}
    >
      <div className="container">
        <div className="try-head">
          <h2 id="try-title" data-split>
            {tryMatch.title}
          </h2>
          <p className="lead" data-rise>
            {tryMatch.description}
          </p>
        </div>
        <div className="try-grid">
          <fieldset className="try-jobs">
            <legend>{tryMatch.jobLegend}</legend>
            {sampleJobs.map((item) => (
              <label className="try-job" key={item.id}>
                <input
                  type="radio"
                  name="sample-job"
                  value={item.id}
                  checked={item.id === jobId}
                  onChange={() => chooseJob(item.id)}
                />
                <span className="try-job-body">
                  <span className="try-job-title">{item.title}</span>
                  <span className="try-job-meta">
                    {item.skills.join(' + ')}
                  </span>
                </span>
              </label>
            ))}
            <p className="try-note">{tryMatch.checksNote}</p>
            <p className="try-note">{tryMatch.sampleNote}</p>
          </fieldset>
          <div className="try-board">
            <p className="try-status" role="status" aria-live="polite">
              {winner
                ? `Booking created. ${winner.worker.name} accepted first.`
                : `${eligible.length} of ${results.length} sample Workers are eligible for this job in ${tryMatch.location}. Any of them can accept.`}
            </p>
            {winner ? (
              <div className="try-result">
                <Mark className="try-result-mark" />
                <div>
                  <h3>The job is booked.</h3>
                  <p>
                    {wonFromBehind
                      ? `${winner.worker.name} was not the top score, and still got the job. The first valid acceptance decides.`
                      : `${winner.worker.name} accepted first, so the booking is theirs. The Client never picks from a list.`}
                  </p>
                </div>
                <button
                  type="button"
                  className="button button-small button-light"
                  onClick={reset}
                >
                  <RotateCcw size={16} aria-hidden="true" />
                  {tryMatch.reset}
                </button>
              </div>
            ) : null}
            <ol className="try-list">
              {results.map((result) => (
                <WorkerRow
                  key={result.worker.id}
                  result={result}
                  job={job}
                  accepted={accepted}
                  onAccept={accept}
                />
              ))}
            </ol>
          </div>
        </div>
      </div>
    </section>
  )
}
