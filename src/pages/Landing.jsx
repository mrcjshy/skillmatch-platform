import { useRef } from 'react'
import Header from '../components/website/Header'
import Hero from '../components/website/Hero'
import TryMatch from '../components/website/TryMatch'
import Experience from '../components/website/Experience'
import {
  HowItWorks,
  Skills,
  Tools,
  About,
  Download,
  Footer,
} from '../components/website/Sections'
import FAQ from '../components/website/FAQ'
import SiteAnalytics from '../components/website/SiteAnalytics'
import useLandingMotion from '../effects/useLandingMotion'

export default function Landing() {
  const page = useRef(null)
  useLandingMotion(page)
  return (
    <div ref={page}>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <Header />
      <main id="main" tabIndex={-1}>
        <Hero />
        <TryMatch />
        <Experience />
        <HowItWorks />
        <Skills />
        <Tools />
        <About />
        <FAQ />
        <Download />
      </main>
      <Footer />
      <SiteAnalytics />
    </div>
  )
}
