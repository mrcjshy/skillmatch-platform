import { useLayoutEffect } from 'react'
import gsap from 'gsap'
import { ScrollTrigger } from 'gsap/ScrollTrigger'
import { SplitText } from 'gsap/SplitText'

gsap.registerPlugin(ScrollTrigger, SplitText)

const PIECE_OFFSET = {
  wide: { x: 300, y: 56 },
  medium: { x: 220, y: 56 },
  narrow: { x: 130, y: 44 },
}
const SMALL_MARK_OFFSET = { x: 240, y: 120 }

// Everything here is set by script, so the page rests finished without it.
function lockTheHero(offset) {
  gsap.set('.piece-worker', { x: offset.x, y: -offset.y })
  gsap.set('.piece-client', { x: -offset.x, y: offset.y })
  gsap.set('.hero-lock', { autoAlpha: 0, y: 28 })

  gsap
    .timeline({ defaults: { duration: 1.15, ease: 'expo.out' } })
    .from('.hero-word-inner', { yPercent: 108, stagger: 0.1 })
    .from('.piece-intro-worker', { x: 150, y: -40 }, 0.1)
    .from('.piece-intro-client', { x: -150, y: 40 }, 0.1)
    .from('.hero-cap', { autoAlpha: 0, duration: 0.7 }, 0.5)
    .from(
      '.hero-copy > *',
      { y: 22, autoAlpha: 0, duration: 0.8, stagger: 0.09 },
      0.42,
    )

  // The tongues pass above and below each other, then drop into the lock.
  gsap
    .timeline({
      defaults: { ease: 'none' },
      scrollTrigger: {
        trigger: '.hero-track',
        start: 'top top',
        end: 'bottom bottom',
        scrub: 0.45,
      },
    })
    .to(
      ['.piece-worker', '.piece-client'],
      { x: 0, duration: 0.5, ease: 'power2.inOut' },
      0,
    )
    .to('.hero-cap', { autoAlpha: 0, duration: 0.08 }, 0.42)
    .to(
      ['.piece-worker', '.piece-client'],
      { y: 0, duration: 0.14, ease: 'power3.in' },
      0.52,
    )
    .to('.hero-mark', { scale: 1.035, duration: 0.03, ease: 'power2.out' }, 0.66)
    .to('.hero-mark', { scale: 1, duration: 0.08, ease: 'power2.inOut' }, 0.69)
    .to('.hero-lock', { autoAlpha: 1, y: 0, duration: 0.1 }, 0.68)
    .to({}, { duration: 0.22 })
}

function splitHeadings() {
  gsap.utils.toArray('[data-split]').forEach((heading) => {
    SplitText.create(heading, {
      type: 'lines',
      mask: 'lines',
      autoSplit: true,
      onSplit: (split) =>
        gsap.from(split.lines, {
          yPercent: 106,
          duration: 0.95,
          ease: 'expo.out',
          stagger: 0.09,
          scrollTrigger: { trigger: heading, start: 'top 86%', once: true },
        }),
    })
  })
}

function riseText() {
  gsap.utils.toArray('[data-rise]').forEach((element) => {
    gsap.from(element, {
      y: 20,
      autoAlpha: 0,
      duration: 0.8,
      ease: 'expo.out',
      scrollTrigger: { trigger: element, start: 'top 90%', once: true },
    })
  })
}

function openShutters() {
  gsap.utils.toArray('[data-shutter]').forEach((element) => {
    gsap.fromTo(
      element,
      { clipPath: 'inset(0% 0% 100% 0%)' },
      {
        clipPath: 'inset(0% 0% 0% 0%)',
        duration: 1.1,
        ease: 'power3.inOut',
        clearProps: 'clipPath',
        scrollTrigger: { trigger: element, start: 'top 88%', once: true },
      },
    )
  })
}

function staggerGroups() {
  const groups = [
    ['.try-job', { x: -18 }, 0.07],
    ['.try-row', { y: 28 }, 0.07],
    ['.tools-column', { y: 24 }, 0.11],
    ['.faq-item', { y: 16 }, 0.05],
  ]
  groups.forEach(([selector, from, stagger]) => {
    gsap.from(selector, {
      ...from,
      autoAlpha: 0,
      duration: 0.75,
      ease: 'expo.out',
      stagger,
      clearProps: 'transform,opacity,visibility',
      scrollTrigger: { trigger: selector, start: 'top 90%', once: true },
    })
  })
  gsap.from('.skill-list span', {
    yPercent: 108,
    duration: 0.8,
    ease: 'expo.out',
    stagger: 0.035,
    scrollTrigger: { trigger: '.skill-list', start: 'top 82%', once: true },
  })
}

// The S locks again wherever the page reaches a match: at "A Worker chooses",
// and beside the app's own words.
function lockTheSmallMarks(hasPlate) {
  const { x, y } = SMALL_MARK_OFFSET
  if (hasPlate) {
    gsap.set('.how-mark .mark-worker', { x, y: -y })
    gsap.set('.how-mark .mark-client', { x: -x, y })
    gsap
      .timeline({
        defaults: { ease: 'none' },
        scrollTrigger: {
          trigger: '.how-copy ol',
          start: 'top 50%',
          end: '62% 50%',
          scrub: 0.4,
        },
      })
      .to(['.how-mark .mark-worker', '.how-mark .mark-client'], { x: 0 })
      .to(['.how-mark .mark-worker', '.how-mark .mark-client'], { y: 0 })
  }
  const trigger = { trigger: '.tools-quote', start: 'top 72%', once: true }
  const lock = { duration: 1.1, ease: 'expo.out', scrollTrigger: trigger }
  gsap.from('.tools-mark .mark-worker', { x, y: -y, ...lock })
  gsap.from('.tools-mark .mark-client', { x: -x, y, ...lock })
}

function moveThePictures() {
  gsap.fromTo(
    '.about-lead img',
    { yPercent: -9 },
    {
      yPercent: 0,
      ease: 'none',
      scrollTrigger: { trigger: '.about-lead', scrub: true },
    },
  )
  gsap.from('.download-word', {
    yPercent: 22,
    ease: 'none',
    scrollTrigger: {
      trigger: '.download',
      start: 'top bottom',
      end: 'bottom bottom',
      scrub: true,
    },
  })
  gsap.from('.footer-name', {
    yPercent: 30,
    ease: 'none',
    scrollTrigger: {
      trigger: '.site-footer',
      start: 'top bottom',
      end: 'bottom bottom',
      scrub: true,
    },
  })
}

export default function useLandingMotion(root) {
  useLayoutEffect(() => {
    const media = gsap.matchMedia(root)
    media.add(
      {
        wide: '(min-width: 1280px) and (prefers-reduced-motion: no-preference)',
        medium:
          '(min-width: 900px) and (max-width: 1279px) and (prefers-reduced-motion: no-preference)',
        narrow:
          '(max-width: 899px) and (prefers-reduced-motion: no-preference)',
      },
      (context) => {
        const { wide, medium } = context.conditions
        lockTheHero(
          wide
            ? PIECE_OFFSET.wide
            : medium
              ? PIECE_OFFSET.medium
              : PIECE_OFFSET.narrow,
        )
        splitHeadings()
        riseText()
        openShutters()
        staggerGroups()
        lockTheSmallMarks(wide || medium)
        moveThePictures()
      },
    )
    return () => media.revert()
  }, [root])
}
