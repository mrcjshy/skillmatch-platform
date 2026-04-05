import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'

function Register() {
  // Hook to redirect user after successful registration
  const navigate = useNavigate()
  // Form state - stores what user types
  const [formData, setFormData] = useState({
    email: '',
    password: '',
    confirmPassword: '',
    full_name: '',
    phone: '',
    role: '',
    barangay: '',
    city: ''
  })

  // Loading state - shows spinner during submission
  const [loading, setLoading] = useState(false)

  // Error state - shows error messages
  const [error, setError] = useState(null)

  // Handle input changes
  const handleChange = (e) => {
    const { name, value } = e.target
    setFormData(prev => ({
      ...prev,
      [name]: value
    }))
  }

// Handle form submission
// Handle form submission
const handleSubmit = async (e) => {
  e.preventDefault()
  setError(null)

  // ============ VALIDATION ============

  if (formData.password !== formData.confirmPassword) {
    setError('Passwords do not match')
    return
  }

  if (formData.password.length < 6) {
    setError('Password must be at least 6 characters')
    return
  }

  const phoneRegex = /^(09|\+639)\d{9}$/
  if (!phoneRegex.test(formData.phone)) {
    setError('Please enter a valid Philippine mobile number (e.g., 09171234567)')
    return
  }

  if (!formData.role) {
    setError('Please select whether you are a Worker or Client')
    return
  }

  if (!formData.full_name.trim()) {
    setError('Please enter your full name')
    return
  }

  if (!formData.barangay.trim()) {
    setError('Please enter your barangay')
    return
  }

  if (!formData.city.trim()) {
    setError('Please enter your city')
    return
  }

  // ============ REGISTER WITH SUPABASE ============

  setLoading(true)

  try {
    // STEP 1: Create auth account
    const { data: authData, error: authError } = await supabase.auth.signUp({
      email: formData.email,
      password: formData.password
    })

    if (authError) {
      throw new Error(authError.message)
    }

    if (!authData.user) {
      throw new Error('Registration failed. Please try again.')
    }

    // STEP 2: Create profile in users table
    const { error: profileError } = await supabase
      .from('users')
      .insert({
        id: authData.user.id,
        email: formData.email,
        full_name: formData.full_name.trim(),
        phone: formData.phone,
        role: formData.role,
        barangay: formData.barangay.trim(),
        city: formData.city.trim()
      })

    if (profileError) {
      throw new Error(profileError.message)
    }

    // STEP 3: Success - go to login page
    alert('Account created successfully! Please log in.')
    navigate('/')

  } catch (err) {
    setError(err.message)
  } finally {
    setLoading(false)
  }
}

  return (
    <div style={styles.container}>
      <div style={styles.formCard}>
        <h1 style={styles.title}>Create Account</h1>
        <p style={styles.subtitle}>Join the SkillMatch platform</p>

        {error && <div style={styles.errorBox}>{error}</div>}

        <form onSubmit={handleSubmit}>
          {/* Email */}
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

          {/* Password */}
          <div style={styles.inputGroup}>
            <label style={styles.label}>Password</label>
            <input
              type="password"
              name="password"
              value={formData.password}
              onChange={handleChange}
              placeholder="Minimum 6 characters"
              style={styles.input}
              required
            />
          </div>

          {/* Confirm Password */}
          <div style={styles.inputGroup}>
            <label style={styles.label}>Confirm Password</label>
            <input
              type="password"
              name="confirmPassword"
              value={formData.confirmPassword}
              onChange={handleChange}
              placeholder="Re-enter your password"
              style={styles.input}
              required
            />
          </div>

          {/* Full Name */}
          <div style={styles.inputGroup}>
            <label style={styles.label}>Full Name</label>
            <input
              type="text"
              name="full_name"
              value={formData.full_name}
              onChange={handleChange}
              placeholder="Juan Dela Cruz"
              style={styles.input}
              required
            />
          </div>

          {/* Phone */}
          <div style={styles.inputGroup}>
            <label style={styles.label}>Phone Number</label>
            <input
              type="tel"
              name="phone"
              value={formData.phone}
              onChange={handleChange}
              placeholder="09171234567"
              style={styles.input}
              required
            />
          </div>

          {/* Role Selection */}
          <div style={styles.inputGroup}>
            <label style={styles.label}>I want to register as:</label>
            <div style={styles.radioGroup}>
              <label style={styles.radioLabel}>
                <input
                  type="radio"
                  name="role"
                  value="worker"
                  checked={formData.role === 'worker'}
                  onChange={handleChange}
                  required
                />
                <span style={styles.radioText}>Worker</span>
                <span style={styles.radioDesc}>I offer services and skills</span>
              </label>
              <label style={styles.radioLabel}>
                <input
                  type="radio"
                  name="role"
                  value="client"
                  checked={formData.role === 'client'}
                  onChange={handleChange}
                />
                <span style={styles.radioText}>Client</span>
                <span style={styles.radioDesc}>I need to hire workers</span>
              </label>
            </div>
          </div>

          {/* Barangay */}
          <div style={styles.inputGroup}>
            <label style={styles.label}>Barangay</label>
            <input
              type="text"
              name="barangay"
              value={formData.barangay}
              onChange={handleChange}
              placeholder="Enter your barangay"
              style={styles.input}
              required
            />
          </div>

          {/* City */}
          <div style={styles.inputGroup}>
            <label style={styles.label}>City / Municipality</label>
            <input
              type="text"
              name="city"
              value={formData.city}
              onChange={handleChange}
              placeholder="Enter your city"
              style={styles.input}
              required
            />
          </div>

          {/* Submit Button */}
          <button
            type="submit"
            style={styles.submitButton}
            disabled={loading}
          >
            {loading ? 'Creating Account...' : 'Create Account'}
          </button>
        </form>

        <p style={styles.loginLink}>
          Already have an account? <Link to="/">Login here</Link>
        </p>
      </div>
    </div>
  )
}

// Styles object
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
    maxWidth: '450px'
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
  radioGroup: {
    display: 'flex',
    flexDirection: 'column',
    gap: '0.75rem'
  },
  radioLabel: {
    display: 'flex',
    alignItems: 'flex-start',
    gap: '0.5rem',
    padding: '0.75rem',
    border: '1px solid #ddd',
    borderRadius: '4px',
    cursor: 'pointer'
  },
  radioText: {
    fontWeight: '500'
  },
  radioDesc: {
    fontSize: '0.85rem',
    color: '#666',
    marginLeft: 'auto'
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
    marginTop: '1rem'
  },
  loginLink: {
    textAlign: 'center',
    marginTop: '1.5rem',
    color: '#666'
  }
}

export default Register