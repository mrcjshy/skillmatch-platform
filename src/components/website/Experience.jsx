import { useLayoutEffect, useRef, useState } from 'react'
import gsap from 'gsap'
import { ArrowLeft, ArrowRight, Check } from 'lucide-react'
import {
  appScreenNote,
  assets,
  experiences,
  pageCopy,
} from '../../content/website'

export default function Experience() {
  const [role, setRole] = useState('worker')
  const [slide, setSlide] = useState(0)
  const tabs = useRef([])
  const screen = useRef(null)
  const firstRender = useRef(true)
  const content = experiences[role]
  const preview = assets[content.previews[slide]]

  function selectRole(next) {
    setRole(next)
    setSlide(0)
  }
  function onTabKey(event, index) {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return
    event.preventDefault()
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? 1 : 1 - index
    selectRole(next === 0 ? 'worker' : 'client')
    tabs.current[next]?.focus()
  }

  useLayoutEffect(() => {
    if (firstRender.current) {
      firstRender.current = false
      return
    }
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const tween = gsap.fromTo(
      screen.current,
      { x: 16, opacity: 0.2 },
      { x: 0, opacity: 1, duration: 0.42, ease: 'expo.out' },
    )
    return () => tween.revert()
  }, [role, slide])

  return (
    <section
      id="experience"
      className="roles"
      aria-labelledby="experience-title"
    >
      <div className={`roles-plate roles-plate-${role}`} data-shutter>
        <figure ref={screen}>
          <img
            key={preview.src}
            src={preview.src}
            alt={preview.alt}
            width={preview.width}
            height={preview.height}
            loading="lazy"
          />
          <figcaption>{preview.label}</figcaption>
        </figure>
        <div className="gallery-controls">
          <button
            type="button"
            aria-label="Previous app preview"
            onClick={() =>
              setSlide(
                (slide + content.previews.length - 1) % content.previews.length,
              )
            }
          >
            <ArrowLeft size={19} aria-hidden="true" />
          </button>
          <span aria-live="polite" aria-atomic="true">
            {slide + 1} / {content.previews.length}
            <span className="sr-only">: {preview.label}</span>
          </span>
          <button
            type="button"
            aria-label="Next app preview"
            onClick={() => setSlide((slide + 1) % content.previews.length)}
          >
            <ArrowRight size={19} aria-hidden="true" />
          </button>
        </div>
        <p className="screen-note">{appScreenNote}</p>
      </div>
      <div className="roles-copy">
        <h2 id="experience-title" data-split>
          {pageCopy.experience.title}
        </h2>
        <p data-rise>{pageCopy.experience.description}</p>
        <div
          className="role-tabs"
          role="tablist"
          aria-label="Choose an app experience"
        >
          {Object.entries(experiences).map(([key, value], index) => (
            <button
              key={key}
              ref={(element) => {
                tabs.current[index] = element
              }}
              type="button"
              id={`tab-${key}`}
              role="tab"
              aria-selected={role === key}
              aria-controls="experience-panel"
              tabIndex={role === key ? 0 : -1}
              onKeyDown={(event) => onTabKey(event, index)}
              onClick={() => selectRole(key)}
            >
              {value.tab}
            </button>
          ))}
        </div>
        <div
          id="experience-panel"
          role="tabpanel"
          aria-labelledby={`tab-${role}`}
          tabIndex={0}
          className="roles-panel"
        >
          <h3>{content.title}</h3>
          <p>{content.description}</p>
          <ul>
            {content.steps.map(([title, description]) => (
              <li key={title}>
                <Check size={20} strokeWidth={3} aria-hidden="true" />
                <div>
                  <h4>{title}</h4>
                  <p>{description}</p>
                </div>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </section>
  )
}
