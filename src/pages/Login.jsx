// useState: Store form data, loading state, error messages
import { useState } from 'react'

// Link: Create clickable links to other pages
// useNavigate: Redirect user programmatically
import { Link, useNavigate } from 'react-router-dom'

// supabase: Our database client
import { supabase } from '../lib/supabase'

function Login() {
  // ============================================
  // STATE VARIABLES
  // ============================================
  
  // navigate: Function to redirect user
  const navigate = useNavigate()

  // formData: Stores what user types in the form
  // We use ONE object to store all form fields
  const [formData, setFormData] = useState({
    email: '',
    password: ''
  })

  // loading: Shows spinner while logging in
  // Prevents user from clicking multiple times
  const [loading, setLoading] = useState(false)

  // error: Stores error message to display
  // null means no error
  const [error, setError] = useState(null)

  // ============================================
  // EVENT HANDLERS
  // ============================================

  // handleChange: Runs every time user types in an input
  // Updates the formData state with new value
  const handleChange = (e) => {
    // e.target = the input element that triggered this
    // name = the "name" attribute of the input
    // value = what the user typed
    const { name, value } = e.target
    
    // Update formData, keeping other fields unchanged
    // ...prev copies existing values
    // [name]: value updates just this field
    setFormData(prev => ({
      ...prev,
      [name]: value
    }))
  }

  // handleSubmit: Runs when form is submitted
  const handleSubmit = async (e) => {
    // Stop browser from refreshing the page
    e.preventDefault()
    
    // Clear any previous errors
    setError(null)

    // ============================================
    // VALIDATION
    // ============================================

    // Check email is not empty
    if (!formData.email.trim()) {
      setError('Please enter your email')
      return  // Stop here, don't continue
    }

    // Check password is not empty
    if (!formData.password) {
      setError('Please enter your password')
      return
    }

    // ============================================
    // LOGIN WITH SUPABASE
    // ============================================

    // Show loading spinner
    setLoading(true)

    try {
      // STEP 1: Attempt to sign in
      // signInWithPassword: Verifies email + password with Supabase Auth
      // Returns: { data: { user, session }, error }
      const { data: authData, error: authError } = await supabase.auth.signInWithPassword({
        email: formData.email,
        password: formData.password
      })

      // If login failed (wrong email/password)
      if (authError) {
        throw new Error(authError.message)
      }

      // STEP 2: Fetch user's role and status from users table
      // We need this to know which dashboard to show
      const { data: userData, error: userError } = await supabase
        .from('users')
        .select('role, is_active')
        .eq('id', authData.user.id)
        .single()

      // If we couldn't find the user's profile
      if (userError) {
        throw new Error('User profile not found. Please contact support.')
      }

      // STEP 3: Check if account is suspended
      // is_active = false means account was suspended (3-strike rule)
      if (!userData.is_active) {
        // Sign them out since they shouldn't have access
        await supabase.auth.signOut()
        throw new Error('Your account has been suspended. Please contact the administrator.')
      }

      // STEP 4: Redirect based on role
      // Each role goes to their specific dashboard
      switch (userData.role) {
        case 'worker':
          navigate('/worker')
          break
        case 'client':
          navigate('/client')
          break
        case 'administrator':
          navigate('/admin')
          break
        default:
          // This shouldn't happen if database is set up correctly
          throw new Error('Invalid user role. Please contact support.')
      }

    } catch (err) {
      // If ANY error happened above, show it to user
      setError(err.message)
    } finally {
      // Always hide loading spinner, whether success or failure
      setLoading(false)
    }
  }

  // ============================================
  // RENDER (What appears on screen)
  // ============================================

  return (
    <div style={styles.container}>
      <div style={styles.formCard}>
        <h1 style={styles.title}>Welcome Back</h1>
        <p style={styles.subtitle}>Sign in to SkillMatch</p>

        {/* Error message box - only shows if error exists */}
        {error && <div style={styles.errorBox}>{error}</div>}

        {/* The login form */}
        <form onSubmit={handleSubmit}>
          
          {/* Email field */}
          <div style={styles.inputGroup}>
            <label style={styles.label}>Email Address</label>
            <input
              type="email"
              name="email"
              value={formData.email}
              onChange={handleChange}
              placeholder="you@example.com"
              style={styles.input}
              required
            />
          </div>

          {/* Password field */}
          <div style={styles.inputGroup}>
            <label style={styles.label}>Password</label>
            <input
              type="password"
              name="password"
              value={formData.password}
              onChange={handleChange}
              placeholder="Enter your password"
              style={styles.input}
              required
            />
          </div>

          {/* Submit button */}
          <button 
            type="submit" 
            style={styles.submitButton}
            disabled={loading}
          >
            {loading ? 'Signing in...' : 'Sign In'}
          </button>
        </form>

        {/* Link to registration page */}
        <p style={styles.registerLink}>
          Don't have an account? <Link to="/register">Register here</Link>
        </p>
      </div>
    </div>
  )
}

// ============================================
// STYLES
// ============================================

const styles = {
  container: {
    minHeight: '100vh',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    padding: '2rem',
    backgroundColor: '#f5f5f5'
  },
  formCard: {
    backgroundColor: '#fff',
    padding: '2rem',
    borderRadius: '8px',
    boxShadow: '0 2px 10px rgba(0, 0, 0, 0.1)',
    width: '100%',
    maxWidth: '400px'
  },
  title: {
    margin: '0 0 0.5rem 0',
    fontSize: '1.75rem',
    color: '#333',
    textAlign: 'center'
  },
  subtitle: {
    margin: '0 0 1.5rem 0',
    color: '#666',
    textAlign: 'center'
  },
  errorBox: {
    backgroundColor: '#fee',
    color: '#c00',
    padding: '0.75rem',
    borderRadius: '4px',
    marginBottom: '1rem',
    fontSize: '0.9rem'
  },
  inputGroup: {
    marginBottom: '1rem'
  },
  label: {
    display: 'block',
    marginBottom: '0.5rem',
    fontWeight: '500',
    color: '#333'
  },
  input: {
    width: '100%',
    padding: '0.75rem',
    border: '1px solid #ddd',
    borderRadius: '4px',
    fontSize: '1rem',
    boxSizing: 'border-box'
  },
  submitButton: {
    width: '100%',
    padding: '0.875rem',
    backgroundColor: '#3b82f6',
    color: '#fff',
    border: 'none',
    borderRadius: '4px',
    fontSize: '1rem',
    fontWeight: '500',
    cursor: 'pointer',
    marginTop: '0.5rem'
  },
  registerLink: {
    textAlign: 'center',
    marginTop: '1.5rem',
    color: '#666'
  }
}

export default Login  