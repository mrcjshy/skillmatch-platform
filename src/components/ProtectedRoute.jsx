import { Navigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'

// This component wraps pages that require authentication
// allowedRoles = which roles can access this page (e.g., ['worker'] or ['administrator'])

function ProtectedRoute({ children, allowedRoles }) {
  const { user, profile, loading } = useAuth()

  // Still checking session - show nothing (AuthProvider shows Loading)
  if (loading) {
    return null
  }

  // Not logged in - redirect to login page
  if (!user) {
    return <Navigate to="/" replace />
  }

  // Logged in but profile not loaded yet - wait
  if (!profile) {
    return (
      <div className="flex min-h-screen items-center justify-center text-xl text-ink-muted">
        <p>Loading profile...</p>
      </div>
    )
  }

  // Check if user's role is allowed for this page
  if (allowedRoles && !allowedRoles.includes(profile.role)) {
    // Redirect to their correct dashboard based on role
    switch (profile.role) {
      case 'worker':
        return <Navigate to="/worker" replace />
      case 'client':
        return <Navigate to="/client" replace />
      case 'administrator':
        return <Navigate to="/admin" replace />
      default:
        return <Navigate to="/" replace />
    }
  }

  // All checks passed - show the page
  return children
}

export default ProtectedRoute