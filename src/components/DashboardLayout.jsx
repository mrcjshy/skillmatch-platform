import { useAuth } from '../hooks/useAuth'

// Shared page shell for the three role dashboards.
// All three previously duplicated the same header + logout button inline styles.

function DashboardLayout({ title, children }) {
  const { signOut } = useAuth()

  return (
    <div className="p-8">
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold text-ink">{title}</h1>
        <button
          onClick={signOut}
          className="cursor-pointer rounded bg-red-500 px-4 py-2 text-white"
        >
          Logout
        </button>
      </div>
      {children}
    </div>
  )
}

export default DashboardLayout
