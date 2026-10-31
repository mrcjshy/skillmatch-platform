import { ArrowDown } from 'lucide-react'
import { hero } from '../../content/website'
import { CLIENT_PIECE, MARK_VIEWBOX, WORKER_PIECE } from './Mark'

// The stage rests with the S already locked. The motion hook parts the pieces, so
// reduced motion and a failed script both show the finished mark. Both pieces
// carry one photograph, which only reads as a whole once they lock.
function Piece({ name }) {
  return (
    <g className={`piece-intro piece-intro-${name}`}>
      <g className={`piece piece-${name}`}>
        <g clipPath={`url(#hero-clip-${name})`}>
          <image
            href="/website/santa-ana-wall.webp"
            x="-212"
            y="72"
            width="1109"
            height="832"
          />
        </g>
      </g>
    </g>
  )
}

export default function Hero() {
  return (
    <section id="home" className="hero" aria-labelledby="hero-title">
      <div className="hero-track">
        <div className="hero-stage">
          <h1 id="hero-title" className="hero-name" aria-label="SkillMatch">
            <span className="hero-word hero-skill" aria-hidden="true">
              <span className="hero-word-inner">Skill</span>
            </span>
            <span className="hero-word hero-match" aria-hidden="true">
              <span className="hero-word-inner">Match</span>
            </span>
          </h1>
          <svg
            className="hero-mark"
            viewBox={MARK_VIEWBOX}
            role="img"
            aria-label={hero.markLabel}
          >
            <defs>
              <clipPath id="hero-clip-worker">
                <path d={WORKER_PIECE} />
              </clipPath>
              <clipPath id="hero-clip-client">
                <path d={CLIENT_PIECE} />
              </clipPath>
            </defs>
            <Piece name="worker" />
            <Piece name="client" />
          </svg>
          <p className="hero-cap hero-cap-worker">{hero.workerPiece}</p>
          <p className="hero-cap hero-cap-client">{hero.clientPiece}</p>
          <p className="hero-lock">
            <span className="hero-lock-word" lang="tl">
              {hero.lockWord}
            </span>
            <span className="hero-lock-meaning">{hero.lockMeaning}</span>
          </p>
          <div className="hero-copy">
            <p>{hero.description}</p>
            <div className="hero-actions">
              <a href="#try" className="button button-light">
                {hero.action}
              </a>
              <a href="#how-it-works" className="text-link text-link-light">
                {hero.secondary}
                <ArrowDown size={18} aria-hidden="true" />
              </a>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
