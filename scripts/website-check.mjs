import assert from 'node:assert/strict'
import { mkdir, writeFile } from 'node:fs/promises'
import { chromium } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { matchWorkers, scoreWorker } from '../src/content/matching.js'
import { sampleJobs, sampleWorkers } from '../src/content/website.js'

const baseURL = process.env.WEBSITE_URL || 'http://127.0.0.1:5173'
const output = '.impeccable/review'
await mkdir(output, { recursive: true })
const browser = await chromium.launch({ channel: 'chrome', headless: true })
const results = []
const consoleErrors = []
const failedRequests = []
async function check(name, run) {
  try {
    await run()
    results.push({ name, passed: true })
    console.log(`PASS ${name}`)
  } catch (error) {
    results.push({ name, passed: false, error: error.message })
    console.error(`FAIL ${name}: ${error.message}`)
  }
}

await check('Matching rules reproduce the two real app scores', async () => {
  const worker = {
    skills: ['Plumbing'],
    barangay: 'Santa Ana',
    city: 'Pateros',
    rating: 4.525,
  }
  const place = { barangay: 'Santa Ana', city: 'Pateros' }
  assert.equal(
    scoreWorker(worker, { ...place, skills: ['Plumbing'] }).total.toFixed(1),
    '98.1',
  )
  assert.equal(
    scoreWorker(worker, {
      ...place,
      skills: ['Plumbing', 'Electrical Work'],
    }).total.toFixed(1),
    '73.1',
  )
})
await check('Matching rules follow the D-002 gate and tiebreaks', async () => {
  const job = sampleJobs[0]
  const base = sampleWorkers[0]
  assert.equal(scoreWorker({ ...base, rating: null }, job).rating, 12)
  assert.equal(scoreWorker({ ...base, barangay: 'Aguho' }, job).location, 10)
  assert.equal(
    scoreWorker({ ...base, barangay: 'Bagumbayan', city: 'Taguig' }, job)
      .location,
    0,
  )
  for (const change of [
    { active: false },
    { available: false },
    { verified: false },
    { skills: ['Sewing'] },
  ])
    assert.equal(matchWorkers([{ ...base, ...change }], job)[0].eligible, false)
  const tied = matchWorkers(
    [
      { ...base, id: 'busy', completedBookings: 9 },
      { ...base, id: 'quiet', completedBookings: 2 },
    ],
    job,
  )
  assert.equal(tied[0].worker.id, 'quiet')
})

async function assertTryMatch(page) {
  // Reads the number the visitor sees, after any count-up has landed.
  const scores = async () => {
    await page.waitForTimeout(750)
    return page.locator('.try-row [data-score]').evaluateAll((items) =>
      items.map((item) => [
        item.closest('.try-row').querySelector('h4').textContent,
        item.textContent,
      ]),
    )
  }
  const outletScores = [
    ['Worker A', '98.0'],
    ['Worker F', '68.8'],
    ['Worker C', '67.0'],
    ['Worker B', '54.2'],
  ]
  assert.deepEqual(await scores(), [
    ['Worker A', '98.0'],
    ['Worker B', '79.2'],
    ['Worker F', '68.8'],
  ])
  assert.match(await page.locator('.try-status').innerText(), /3 of 6/)
  await page.getByLabel(/Sink pipe and a sparking outlet/).check({ force: true })
  assert.deepEqual(await scores(), outletScores)
  const notVerified = page.locator('.try-row', { hasText: 'Worker D' })
  assert.match(await notVerified.innerText(), /ID not verified yet/)
  await page.getByRole('button', { name: 'Accept as Worker B' }).click()
  assert.match(
    await page.locator('.try-status').innerText(),
    /Booking created\. Worker B accepted first\./,
  )
  assert.match(
    await page.locator('.try-result').innerText(),
    /not the top score, and still got the job/,
  )
  assert.match(
    await page.locator('.try-row', { hasText: 'Worker A' }).innerText(),
    /Job taken/,
  )
  assert.equal(
    await page.getByRole('button', { name: /^Accept as/ }).count(),
    0,
  )
  assert.deepEqual(await scores(), outletScores)
  await page.getByRole('button', { name: 'Clear and try again' }).click()
  assert.equal(
    await page.getByRole('button', { name: /^Accept as/ }).count(),
    4,
  )
  assert.deepEqual(await scores(), outletScores)
  await page.getByLabel(/Leaking kitchen sink/).check({ force: true })
  await page.waitForTimeout(80)
  await page.getByLabel(/Aircon not cooling/).check({ force: true })
  assert.deepEqual(await scores(), [
    ['Worker C', '92.0'],
    ['Worker F', '68.8'],
  ])
  await page.getByLabel(/Leaking kitchen sink/).check({ force: true })
}

try {
  for (const [width, height, file] of [
    [320, 812, 'user-320'],
    [390, 844, 'mobile'],
    [768, 1024, 'user-768'],
    [1024, 768, 'user-1024'],
    [1280, 720, 'user-1280'],
    [1440, 1000, 'desktop'],
  ]) {
    const context = await browser.newContext({
      viewport: { width, height },
      reducedMotion: 'reduce',
    })
    const page = await context.newPage()
    page.on('pageerror', (error) => consoleErrors.push(error.message))
    page.on('console', (message) => {
      if (message.type() === 'error') consoleErrors.push(message.text())
    })
    page.on('requestfailed', (request) => failedRequests.push(request.url()))
    await page.goto(baseURL, { waitUntil: 'networkidle' })
    await page.evaluate(() => document.fonts.ready)
    await check(
      `${width}px: all sections, no overflow or broken images`,
      async () => {
        assert.equal(await page.locator('h1').count(), 1)
        for (const id of [
          'home',
          'try',
          'experience',
          'how-it-works',
          'skills',
          'tools',
          'about',
          'faq',
          'download',
        ])
          assert.equal(await page.locator(`#${id}`).count(), 1)
        const dimensions = await page.evaluate(() => ({
          width: innerWidth,
          scroll: document.documentElement.scrollWidth,
        }))
        assert.ok(
          dimensions.scroll <= dimensions.width,
          JSON.stringify(dimensions),
        )
        await page.evaluate(async () => {
          document
            .querySelectorAll('img[loading="lazy"]')
            .forEach((image) => (image.loading = 'eager'))
          await Promise.all(
            [...document.images].map((image) => image.decode().catch(() => {})),
          )
        })
        assert.equal(
          await page
            .locator('img')
            .evaluateAll(
              (images) =>
                images.filter((img) => !img.complete || img.naturalWidth === 0)
                  .length,
            ),
          0,
        )
        const brokenAnchors = await page
          .locator('a[href^="#"]')
          .evaluateAll((links) =>
            links
              .filter((link) => !document.getElementById(link.hash.slice(1)))
              .map((link) => link.hash),
          )
        assert.deepEqual(brokenAnchors, [])
      },
    )
    await check(`${width}px: real logo in the header`, async () => {
      const logo = page.locator('.brand-link img')
      assert.equal(
        await logo.getAttribute('src'),
        '/website/skillmatch-logo.png',
      )
      assert.ok((await logo.evaluate((img) => img.naturalWidth)) === 1024)
    })
    await check(`${width}px: headings stay on two lines or fewer`, async () => {
      const tooTall = await page.locator('h2').evaluateAll((headings) =>
        headings
          .filter((heading) => {
            const size = parseFloat(getComputedStyle(heading).lineHeight)
            return heading.getBoundingClientRect().height > size * 2.2
          })
          .map((heading) => heading.textContent),
      )
      assert.deepEqual(tooTall, [])
    })
    await check(`${width}px: automated accessibility scan`, async () => {
      const audit = await new AxeBuilder({ page })
        .withTags(['wcag2a', 'wcag2aa', 'wcag21aa'])
        .analyze()
      assert.deepEqual(
        audit.violations.map((item) => ({
          id: item.id,
          nodes: item.nodes.map((node) => node.target),
        })),
        [],
      )
    })
    await page.screenshot({ path: `${output}/${file}.png`, fullPage: true })
    if (width === 390 || width === 1440)
      await page.screenshot({ path: `${output}/${file}-hero.png` })
    await check(`${width}px: try a match uses the real rules`, () =>
      assertTryMatch(page),
    )
    await check(`${width}px: role tabs and gallery`, async () => {
      const caption = () => page.locator('.roles-plate figcaption').innerText()
      await page.getByRole('tab', { name: 'For Clients' }).click()
      assert.equal(
        await page
          .getByRole('tab', { name: 'For Clients' })
          .getAttribute('aria-selected'),
        'true',
      )
      assert.match(
        await page.locator('.roles-panel h3').innerText(),
        /A job to get done/,
      )
      assert.equal(await caption(), 'Post a job')
      await page.getByRole('button', { name: 'Next app preview' }).click()
      assert.equal(await caption(), 'Awaiting workers')
      await page.getByRole('button', { name: 'Next app preview' }).click()
      assert.equal(await caption(), 'Open to eligible Workers')
      await page.getByRole('button', { name: 'Next app preview' }).click()
      assert.equal(await caption(), 'Post a job')
      await page.getByRole('button', { name: 'Previous app preview' }).click()
      assert.equal(await caption(), 'Open to eligible Workers')
      await page.getByRole('tab', { name: 'For Clients' }).focus()
      await page.keyboard.press('ArrowLeft')
      assert.equal(
        await page
          .getByRole('tab', { name: 'For Workers' })
          .getAttribute('aria-selected'),
        'true',
      )
      assert.equal(await caption(), 'Available jobs')
    })
    await check(
      `${width}px: FAQ keyboard toggle and download state`,
      async () => {
        const faq = page.getByRole('button', {
          name: 'How are opportunities matched?',
        })
        await faq.focus()
        await page.keyboard.press('Enter')
        assert.equal(await faq.getAttribute('aria-expanded'), 'true')
        assert.equal(await page.locator('#faq-answer-2').isVisible(), true)
        await page.keyboard.press('Space')
        assert.equal(await faq.getAttribute('aria-expanded'), 'false')
        assert.equal(await page.locator('#faq-answer-2').isVisible(), false)
        assert.equal(
          await page
            .getByRole('button', { name: 'Download coming soon' })
            .isDisabled(),
          true,
        )
        assert.equal(await page.locator('#download a').count(), 0)
        assert.equal(await page.locator('#download img').count(), 0)
      },
    )
    if (width < 900)
      await check(
        `${width}px: mobile menu, Escape, section navigation`,
        async () => {
          await page.evaluate(() => window.scrollTo(0, 0))
          await page.getByRole('button', { name: 'Open navigation' }).click()
          assert.equal(
            await page
              .getByRole('navigation', { name: 'Mobile navigation' })
              .isVisible(),
            true,
          )
          await page.keyboard.press('Escape')
          assert.equal(
            await page
              .getByRole('button', { name: 'Open navigation' })
              .getAttribute('aria-expanded'),
            'false',
          )
          await page.getByRole('button', { name: 'Open navigation' }).click()
          await page
            .getByRole('navigation', { name: 'Mobile navigation' })
            .getByRole('link', { name: 'About' })
            .click()
          assert.equal(new URL(page.url()).hash, '#about')
          assert.equal(
            await page
              .getByRole('navigation', { name: 'Mobile navigation' })
              .isVisible(),
            false,
          )
          const position = await page.locator('#about').boundingBox()
          assert.ok(
            position.y >= 60 && position.y < 120,
            `Anchor top ${position.y}`,
          )
        },
      )
    await check(`${width}px: real app clip stays still`, async () => {
      const clips = page.locator('video')
      assert.ok((await clips.count()) >= 1)
      assert.equal(
        await clips.evaluateAll((items) =>
          items.every((item) => item.paused && item.muted),
        ),
        true,
      )
    })
    await check(`${width}px: reduced motion rests on the locked S`, async () => {
      assert.equal(
        await page.evaluate(
          () => getComputedStyle(document.documentElement).scrollBehavior,
        ),
        'auto',
      )
      for (const piece of ['.piece-worker', '.piece-client']) {
        assert.equal(await page.locator(piece).getAttribute('style'), null)
        assert.equal(await page.locator(piece).getAttribute('transform'), null)
      }
      assert.equal(await page.locator('.hero-lock').isVisible(), true)
      assert.equal(await page.locator('.hero-mark image').count(), 2)
    })
    await context.close()
  }
  const page = await browser.newPage({
    viewport: { width: 1440, height: 1000 },
  })
  await check('Normal motion: the S parts, then locks on scroll', async () => {
    await page.goto(baseURL, { waitUntil: 'networkidle' })
    await page.waitForTimeout(1500)
    assert.equal(await page.locator('h1').isVisible(), true)
    const offset = () =>
      page.locator('.piece-worker').evaluate((piece) => {
        const { e, f } = piece.transform.baseVal.consolidate().matrix
        return [Math.round(e), Math.round(f)]
      })
    assert.deepEqual(await offset(), [300, -56])
    await page.screenshot({ path: `${output}/desktop-motion.png` })
    await page.evaluate(() => {
      const track = document.querySelector('.hero-track')
      window.scrollTo({
        top: track.offsetTop + track.offsetHeight - innerHeight,
        behavior: 'instant',
      })
    })
    await page.waitForTimeout(1200)
    assert.deepEqual(await offset(), [0, 0])
    assert.equal(await page.locator('.hero-lock').isVisible(), true)
    await page.screenshot({ path: `${output}/desktop-locked.png` })
  })
  await check('Normal motion: nothing stays hidden after scrolling', async () => {
    const height = await page.evaluate(
      () => document.documentElement.scrollHeight,
    )
    for (let top = 0; top < height; top += 600) {
      await page.evaluate(
        (y) => window.scrollTo({ top: y, behavior: 'instant' }),
        top,
      )
      await page.waitForTimeout(120)
    }
    await page.waitForTimeout(1200)
    const hidden = await page
      .locator(
        '[data-rise], [data-split], [data-shutter], .try-row, .try-job, .tools-column, .faq-item, .skill-list span',
      )
      .evaluateAll((items) =>
        items
          .filter((item) => {
            const style = getComputedStyle(item)
            return style.visibility === 'hidden' || Number(style.opacity) < 0.99
          })
          .map((item) => item.textContent.slice(0, 40)),
      )
    assert.deepEqual(hidden, [])
  })
  await check('Normal motion: try a match still works', async () => {
    await page.goto(baseURL, { waitUntil: 'networkidle' })
    await page.locator('#try').scrollIntoViewIfNeeded()
    await page.waitForTimeout(900)
    await assertTryMatch(page)
  })
  await check(
    'Unknown operational route returns to the public page',
    async () => {
      await page.goto(`${baseURL}/worker`, { waitUntil: 'networkidle' })
      assert.equal(new URL(page.url()).pathname, '/')
      assert.equal(await page.locator('h1').getAttribute('aria-label'), 'SkillMatch')
    },
  )
  await check(
    'No backend, analytics, or third-party runtime requests',
    async () => {
      const requests = []
      page.on('request', (request) => requests.push(request.url()))
      await page.goto(baseURL, { waitUntil: 'networkidle' })
      assert.deepEqual(
        requests.filter((url) => !url.startsWith(baseURL)),
        [],
      )
      assert.deepEqual(
        requests.filter((url) => /supabase|insights|analytics/.test(url)),
        [],
      )
    },
  )
  await check(
    'No browser console errors or failed asset requests',
    async () => {
      assert.deepEqual(consoleErrors, [])
      assert.deepEqual(failedRequests, [])
    },
  )
  await page.close()
} finally {
  await browser.close()
  await writeFile(
    `${output}/validation.json`,
    JSON.stringify(
      { baseURL, results, consoleErrors, failedRequests },
      null,
      2,
    ),
  )
}
console.log(
  `${results.filter((result) => result.passed).length}/${results.length} checks passed`,
)
if (results.some((result) => !result.passed)) process.exitCode = 1
