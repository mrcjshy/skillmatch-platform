import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'

// Shared auth page shell + form field classes
import AuthLayout, {
  fieldClass,
  inputClass,
  labelClass,
  submitButtonClass
} from '../components/AuthLayout'

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
    <AuthLayout
      title="Create Account"
      subtitle="Join the SkillMatch platform"
      error={error}
      maxWidthClass="max-w-[450px]"
    >
      <form onSubmit={handleSubmit}>
        {/* Email Address */}
        <div className={fieldClass}>
          <label className={labelClass}>Email Address</label>
          <input
            type="email"
            name="email"
            value={formData.email}
            onChange={handleChange}
            placeholder="you@example.com"
            className={inputClass}
            required
          />
        </div>

        {/* Password */}
        <div className={fieldClass}>
          <label className={labelClass}>Password</label>
          <input
            type="password"
            name="password"
            value={formData.password}
            onChange={handleChange}
            placeholder="Minimum 6 characters"
            className={inputClass}
            required
          />
        </div>

        {/* Confirm Password */}
        <div className={fieldClass}>
          <label className={labelClass}>Confirm Password</label>
          <input
            type="password"
            name="confirmPassword"
            value={formData.confirmPassword}
            onChange={handleChange}
            placeholder="Re-enter your password"
            className={inputClass}
            required
          />
        </div>

        {/* Full Name */}
        <div className={fieldClass}>
          <label className={labelClass}>Full Name</label>
          <input
            type="text"
            name="full_name"
            value={formData.full_name}
            onChange={handleChange}
            placeholder="Juan Dela Cruz"
            className={inputClass}
            required
          />
        </div>

        {/* Phone Number */}
        <div className={fieldClass}>
          <label className={labelClass}>Phone Number</label>
          <input
            type="tel"
            name="phone"
            value={formData.phone}
            onChange={handleChange}
            placeholder="09171234567"
            className={inputClass}
            required
          />
        </div>

        {/* Role Selection */}
        <div className={fieldClass}>
          <label className={labelClass}>I want to register as:</label>
          <div className="flex flex-col gap-3">
            <label className="flex cursor-pointer items-start gap-2 rounded border border-[#ddd] p-3">
              <input
                type="radio"
                name="role"
                value="worker"
                checked={formData.role === 'worker'}
                onChange={handleChange}
                required
              />
              <span className="font-medium">Worker</span>
              <span className="ml-auto text-[0.85rem] text-ink-muted">I offer services and skills</span>
            </label>
            <label className="flex cursor-pointer items-start gap-2 rounded border border-[#ddd] p-3">
              <input
                type="radio"
                name="role"
                value="client"
                checked={formData.role === 'client'}
                onChange={handleChange}
              />
              <span className="font-medium">Client</span>
              <span className="ml-auto text-[0.85rem] text-ink-muted">I need to hire workers</span>
            </label>
          </div>
        </div>

        {/* Barangay */}
        <div className={fieldClass}>
          <label className={labelClass}>Barangay</label>
          <input
            type="text"
            name="barangay"
            value={formData.barangay}
            onChange={handleChange}
            placeholder="Enter your barangay"
            className={inputClass}
            required
          />
        </div>

        {/* City / Municipality */}
        <div className={fieldClass}>
          <label className={labelClass}>City / Municipality</label>
          <input
            type="text"
            name="city"
            value={formData.city}
            onChange={handleChange}
            placeholder="Enter your city"
            className={inputClass}
            required
          />
        </div>

        {/* Submit Button */}
        <button
          type="submit"
          className={submitButtonClass + ' mt-4'}
          disabled={loading}
        >
          {loading ? 'Creating Account...' : 'Create Account'}
        </button>
      </form>

      <p className="mt-6 text-center text-ink-muted">
        Already have an account? <Link to="/">Login here</Link>
      </p>
    </AuthLayout>
  )
}

export default Register
