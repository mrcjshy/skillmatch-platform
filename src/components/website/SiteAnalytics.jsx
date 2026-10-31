import { lazy, Suspense } from 'react'
import { analytics } from '../../content/website'
const Analytics = lazy(() =>
  import('@vercel/analytics/react').then((module) => ({
    default: module.Analytics,
  })),
)
export default function SiteAnalytics() {
  // Disabled until a later authorized deployment; no custom event payloads.
  if (!analytics.enabled || !import.meta.env.PROD) return null
  return (
    <Suspense fallback={null}>
      <Analytics
        beforeSend={(event) => ({
          ...event,
          url: new URL('/', event.url).href,
        })}
      />
    </Suspense>
  )
}
