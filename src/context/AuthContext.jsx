import { createContext, useContext, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

const AuthContext = createContext({})

export const useAuth = () => useContext(AuthContext)

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null)
  const [profile, setProfile] = useState(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    // Listen for auth changes - this handles everything
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      async (event, session) => {
        console.log('Auth event:', event)
        
        if (session?.user) {
          setUser(session.user)
          
          // Fetch profile - use setTimeout to avoid Supabase deadlock
          setTimeout(async () => {
            const { data: profileData } = await supabase
              .from('users')
              .select('*')
              .eq('id', session.user.id)
              .single()
            
            setProfile(profileData)
            setLoading(false)
          }, 0)
        } else {
          setUser(null)
          setProfile(null)
          setLoading(false)
        }
      }
    )

    // Trigger initial check
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session) {
        setLoading(false)
      }
      // If session exists, onAuthStateChange will handle it
    })

    return () => subscription.unsubscribe()
  }, [])

  const signOut = async () => {
    await supabase.auth.signOut()
    setUser(null)
    setProfile(null)
  }

  if (loading) {
    return (
      <div style={loadingStyle}>
        <p>Loading...</p>
      </div>
    )
  }

  return (
    <AuthContext.Provider value={{ user, profile, loading, signOut }}>
      {children}
    </AuthContext.Provider>
  )
}

const loadingStyle = {
  minHeight: '100vh',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  fontSize: '1.25rem',
  color: '#666'
}