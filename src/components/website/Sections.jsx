import { useEffect, useRef, useState } from 'react'
import { ArrowUp, ArrowUpRight, Download as DownloadIcon } from 'lucide-react'
import {
  appScreenNote,
  assets,
  download,
  footerLinks,
  journey,
  pageCopy,
  skills,
} from '../../content/website'
import Mark from './Mark'

// Plays only while on screen, and never under reduced motion, where the poster stays.
function AppClip({ asset, decorative }) {
  const video = useRef(null)
  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const element = video.current
    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) element.play().catch(() => {})
      else element.pause()
    })
    observer.observe(element)
    return () => observer.disconnect()
  }, [])
  return (
    <video
      ref={video}
      src={asset.src}
      poster={asset.poster}
      width={asset.width}
      height={asset.height}
      aria-label={decorative ? undefined : asset.alt}
      muted
      loop
      playsInline
      preload="none"
    />
  )
}

function AppScreen({ name, decorative }) {
  const asset = assets[name]
  if (asset.poster) return <AppClip asset={asset} decorative={decorative} />
  return (
    <img
      src={asset.src}
      alt={decorative ? '' : asset.alt}
      width={asset.width}
      height={asset.height}
      loading="lazy"
    />
  )
}

export function HowItWorks() {
  const [active, setActive] = useState(0)
  const steps = useRef([])
  useEffect(() => {
    // Plain observer: the plate has to follow the text with motion off as well.
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting)
            setActive(steps.current.indexOf(entry.target))
        })
      },
      { rootMargin: '-45% 0px -45% 0px' },
    )
    steps.current.forEach((step) => observer.observe(step))
    return () => observer.disconnect()
  }, [])
  return (
    <section
      id="how-it-works"
      className="how section-pad"
      aria-labelledby="how-title"
    >
      <div className="container how-grid">
        <div className="how-copy">
          <h2 id="how-title" data-split>
            {pageCopy.how.title}
          </h2>
          <p className="how-lead" data-rise>
            {pageCopy.how.description}
          </p>
          <ol>
            {journey.map((step, index) => (
              <li
                key={step.title}
                ref={(element) => {
                  steps.current[index] = element
                }}
              >
                <p data-rise>
                  <strong>{step.title}</strong> {step.description}
                </p>
                <div className="how-inline">
                  <AppScreen name={step.asset} />
                </div>
              </li>
            ))}
          </ol>
          <p className="screen-note">{appScreenNote}</p>
        </div>
        <div className="how-plate" aria-hidden="true">
          <Mark className="how-mark" />
          {journey.map((step, index) => (
            <div
              key={step.title}
              className={index === active ? 'is-active' : ''}
            >
              <AppScreen name={step.asset} decorative />
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}

export function Skills() {
  return (
    <section
      id="skills"
      className="skills section-pad"
      aria-labelledby="skills-title"
    >
      <div className="container">
        <h2 id="skills-title" data-split>
          {pageCopy.skills.title}
        </h2>
        <ul className="skill-list">
          {skills.map((skill) => (
            <li key={skill}>
              <span>{skill}</span>
            </li>
          ))}
        </ul>
        <p className="skills-note" data-rise>
          {pageCopy.skills.description}
        </p>
      </div>
    </section>
  )
}

export function Tools() {
  const copy = pageCopy.tools
  return (
    <section id="tools" className="tools" aria-labelledby="tools-title">
      <div className="container section-pad">
        <h2 id="tools-title" data-split>
          {copy.title}
        </h2>
        <div className="tools-columns">
          {copy.groups.map((group) => (
            <div className="tools-column" key={group.title}>
              <h3>{group.title}</h3>
              <ul>
                {group.items.map((item) => (
                  <li key={item}>{item}</li>
                ))}
              </ul>
              <p>{group.description}</p>
            </div>
          ))}
        </div>
      </div>
      <blockquote className="tools-quote">
        <div className="container tools-quote-inner">
          <div data-rise>
            <p lang="tl">{copy.quote}</p>
            <footer>{copy.quoteSource}</footer>
          </div>
          <Mark className="tools-mark" />
        </div>
      </blockquote>
    </section>
  )
}

function Photo({ photo }) {
  return (
    <img
      src={photo.src}
      alt={photo.alt}
      width={photo.width}
      height={photo.height}
      loading="lazy"
    />
  )
}

export function About() {
  const copy = pageCopy.about
  return (
    <section id="about" className="about" aria-labelledby="about-title">
      <figure className="about-lead">
        <div className="about-lead-frame">
          <Photo photo={copy.photos.lead} />
        </div>
        <figcaption className="container">{copy.photoNote}</figcaption>
      </figure>
      <div className="container about-grid">
        <div className="about-text">
          <h2 id="about-title" data-split>
            {copy.title}
          </h2>
          <p className="lead" data-rise>
            {copy.introduction}
          </p>
          <p data-rise>{copy.description}</p>
        </div>
        <figure data-shutter>
          <Photo photo={copy.photos.street} />
        </figure>
        <figure data-shutter>
          <Photo photo={copy.photos.lane} />
        </figure>
        <p className="about-closing" data-rise>
          {copy.closing}
        </p>
      </div>
    </section>
  )
}

export function Download() {
  const copy = pageCopy.download
  const qr = assets.DOWNLOAD_QR
  const ready = Boolean(download.apkUrl)
  return (
    <section
      id="download"
      className="download"
      aria-labelledby="download-title"
    >
      <div className="container download-top">
        <div>
          <h2 id="download-title" data-split>
            {copy.title}
          </h2>
          <p data-rise>{copy.description}</p>
        </div>
        <div className="download-action" data-rise>
          {ready ? (
            <a className="button button-light" href={download.apkUrl}>
              <DownloadIcon size={20} aria-hidden="true" />
              Download for Android
            </a>
          ) : (
            <button className="button button-light" type="button" disabled>
              Download coming soon
            </button>
          )}
          <p>{download.availability}</p>
          {ready && qr.src ? (
            <img src={qr.src} alt={qr.alt} width="160" height="160" />
          ) : null}
        </div>
      </div>
      <p className="download-word" aria-hidden="true">
        {ready ? copy.readyWord : copy.word}
      </p>
    </section>
  )
}

export function Footer() {
  const copy = pageCopy.footer
  const links = Object.values(footerLinks).filter(Boolean)
  return (
    <footer className="site-footer">
      <p className="footer-name" aria-hidden="true">
        SkillMatch
      </p>
      <div className="container footer-row">
        <div className="footer-brand">
          <Mark className="footer-mark" />
          <div>
            <p>{copy.project}</p>
            <p>{copy.location}</p>
          </div>
        </div>
        <div className="footer-meta">
          <p>
            {copy.credit}{' '}
            <a
              href={copy.creditLink.href}
              target="_blank"
              rel="noreferrer noopener"
            >
              {copy.creditLink.label}
              <ArrowUpRight size={15} aria-hidden="true" />
            </a>
          </p>
          {links.map((link) => (
            <a key={link.href} href={link.href}>
              {link.label}
            </a>
          ))}
          <a className="footer-top" href="#home">
            {copy.top}
            <ArrowUp size={16} aria-hidden="true" />
          </a>
        </div>
      </div>
    </footer>
  )
}
