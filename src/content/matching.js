// The public demo runs the locked D-002 rules: an eligibility gate, then a
// 50 skill / 30 location / 20 rating score. The app's own matching runs on the
// backend and never reads this file.
const NEW_WORKER_RATING_POINTS = 12

export const eligibilityRules = [
  {
    id: 'active',
    label: 'Active',
    passes: (worker) => worker.active,
    failure: 'Account is suspended',
  },
  {
    id: 'available',
    label: 'Available',
    passes: (worker) => worker.available,
    failure: 'Not available right now',
  },
  {
    id: 'verified',
    label: 'Verified',
    passes: (worker) => worker.verified,
    failure: 'ID not verified yet',
  },
  {
    id: 'skill',
    label: 'Skill',
    passes: (worker, job) =>
      job.skills.some((skill) => worker.skills.includes(skill)),
    failure: 'No required skill',
  },
]

export function scoreWorker(worker, job) {
  const matched = job.skills.filter((skill) => worker.skills.includes(skill))
  const skill = (matched.length / job.skills.length) * 50
  const sameCity = worker.city === job.city
  const location = sameCity ? (worker.barangay === job.barangay ? 30 : 10) : 0
  const rating =
    worker.rating === null ? NEW_WORKER_RATING_POINTS : (worker.rating / 5) * 20
  return { skill, location, rating, total: skill + location + rating, matched }
}

function compareRanked(a, b) {
  return (
    b.score.total - a.score.total ||
    a.worker.completedBookings - b.worker.completedBookings ||
    a.worker.registered.localeCompare(b.worker.registered)
  )
}

export function matchWorkers(workers, job) {
  const results = workers.map((worker) => {
    const failedRule = eligibilityRules.find(
      (rule) => !rule.passes(worker, job),
    )
    return {
      worker,
      failedRule: failedRule ?? null,
      eligible: !failedRule,
      score: failedRule ? null : scoreWorker(worker, job),
    }
  })
  return [
    ...results.filter((result) => result.eligible).sort(compareRanked),
    ...results.filter((result) => !result.eligible),
  ]
}
