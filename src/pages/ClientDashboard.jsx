import { useAuth } from '../hooks/useAuth'
import DashboardLayout from '../components/DashboardLayout'

function ClientDashboard() {
  const { profile } = useAuth()

  return (
    <DashboardLayout title="Client Dashboard">
      <p>Welcome, {profile?.full_name || 'Client'}! You can post jobs and find workers here.</p>
    </DashboardLayout>
  )
}

export default ClientDashboard
