import { useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'

function WorkerDashboard() {
  const navigate = useNavigate()

  const handleLogout = async () => {
    await supabase.auth.signOut()
    navigate('/')
  }

  return (
    <div style={{ padding: '2rem' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <h1>Worker Dashboard</h1>
        <button onClick={handleLogout} style={logoutStyle}>
          Logout
        </button>
      </div>
      <p>Welcome, Worker! Your job notifications will appear here.</p>
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

export default WorkerDashboard