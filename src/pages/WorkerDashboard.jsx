import { useAuth } from '../hooks/useAuth'
import DashboardLayout from '../components/DashboardLayout'

function WorkerDashboard() {
  const { profile } = useAuth()

  return (
    <DashboardLayout title="Worker Dashboard">
      <p>Welcome, {profile?.full_name || 'Worker'}! Your job notifications will appear here.</p>
    </DashboardLayout>
  )
}

export default WorkerDashboard
