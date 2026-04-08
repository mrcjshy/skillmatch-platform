import { useAuth } from '../context/AuthContext'

function ClientDashboard() {
  const { profile, signOut } = useAuth()

  return (
    <div style={{ padding: '2rem' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <h1>Client Dashboard</h1>
        <button onClick={signOut} style={logoutStyle}>
          Logout
        </button>
      </div>
      <p>Welcome, {profile?.full_name || 'Client'}! You can post jobs and find workers here.</p>
    </div>
  )
}

const logoutStyle = {
  padding: '0.5rem 1rem',
  backgroundColor: '#ef4444',
  color: 'white',
  border: 'none',
  borderRadius: '4px',
  cursor: 'pointer'
}

export default ClientDashboard