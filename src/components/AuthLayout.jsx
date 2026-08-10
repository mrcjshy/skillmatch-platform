// Shared page shell for the public auth screens (Login / Register).
// Both pages previously duplicated the same centered-card markup as inline styles.

function AuthLayout({ title, subtitle, error, maxWidthClass = 'max-w-[400px]', children }) {
  return (
    <div className="flex min-h-screen items-center justify-center bg-page p-8">
      <div
        className={`w-full ${maxWidthClass} rounded-lg bg-white p-8 shadow-[0_2px_10px_rgba(0,0,0,0.1)]`}
      >
        <h1 className="mb-2 text-center text-[1.75rem] font-bold text-ink">{title}</h1>
        <p className="mb-6 text-center text-ink-muted">{subtitle}</p>

        {/* Error message box - only shows if error exists */}
        {error && (
          <div className="mb-4 rounded bg-[#fee] p-3 text-[0.9rem] text-[#c00]">{error}</div>
        )}

        {children}
      </div>
    </div>
  )
}

// Shared field class strings so the form markup stays readable.
export const labelClass = 'mb-2 block font-medium text-ink'
export const inputClass = 'w-full rounded border border-[#ddd] p-3 text-base'
export const fieldClass = 'mb-4'
export const submitButtonClass =
  'w-full cursor-pointer rounded bg-blue-500 py-3.5 text-base font-medium text-white disabled:cursor-not-allowed disabled:opacity-60'

export default AuthLayout
