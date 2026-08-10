import { createContext } from 'react'

// The context object lives in its own module so that AuthContext.jsx exports
// only the AuthProvider component. Mixing component and non-component exports
// in one file breaks Vite's fast refresh (react-refresh/only-export-components).
export const AuthContext = createContext({})
