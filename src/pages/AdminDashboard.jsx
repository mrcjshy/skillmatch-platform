import { useAuth } from '../hooks/useAuth'
import DashboardLayout from '../components/DashboardLayout'

function AdminDashboard() {
  const { profile } = useAuth()

  return (
    <DashboardLayout title="Admin Dashboard">
      <p>
        Welcome, {profile?.full_name || 'Administrator'}! Manage users, verify workers, and monitor
        bookings here.
      </p>
    </DashboardLayout>
  )
}

export default AdminDashboard
