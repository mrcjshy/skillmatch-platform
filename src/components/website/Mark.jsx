// Two-piece vector of the app's skillmatch-logo.png, traced to within 1px at 1024.
// The pieces slide apart without colliding because their tongues sit on separate levels.
export const WORKER_PIECE =
  'M864 102H400C267 102 160 209 160 342V378C160 488 249 578 360 578H376V478H600V426H360C334 426 312 404 312 378V342C312 294 352 254 400 254H864Z'
export const CLIENT_PIECE =
  'M160 902H624C757 902 864 795 864 662V626C864 516 775 426 664 426H648V526H424V578H664C690 578 712 600 712 626V662C712 710 672 750 624 750H160Z'
export const MARK_VIEWBOX = '130 72 764 860'

export default function Mark({ className }) {
  return (
    <svg
      className={className}
      viewBox={MARK_VIEWBOX}
      aria-hidden="true"
      focusable="false"
    >
      <path className="mark-worker" d={WORKER_PIECE} fill="currentColor" />
      <path className="mark-client" d={CLIENT_PIECE} fill="currentColor" />
    </svg>
  )
}
