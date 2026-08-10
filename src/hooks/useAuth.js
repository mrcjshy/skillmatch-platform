import { useContext } from 'react'
import { AuthContext } from '../context/auth-context'

// Moved out of AuthContext.jsx so that file exports only AuthProvider.
// Behavior is unchanged: this returns { user, profile, loading, signOut }.
export const useAuth = () => useContext(AuthContext)
