import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import Landing from './pages/Landing'

// D-009 (LOCKED): this web application is the public landing/information site
// only. The Worker, Client, and Administrator interfaces belong to the native
// SkillMatch application, so no operational route exists here — the former
// /register, /worker, /client and /admin routes were retired.
function App() {
  return (
    <BrowserRouter>
      <Routes>
        {/* The only page this site serves */}
        <Route path="/" element={<Landing />} />

        {/* Anything else — including stale bookmarks to the retired routes —
            returns to the landing page rather than rendering nothing. */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  )
}

export default App
