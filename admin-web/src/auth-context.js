import { createContext, useContext, useEffect } from 'react';

export const AuthContext = createContext(null);

/** Session state and actions from AuthProvider (src/auth.jsx). */
export function useAuth() {
  const value = useContext(AuthContext);
  if (value === null) throw new Error('useAuth must be used inside AuthProvider');
  return value;
}

/** Sets the document title for a page. */
export function usePageTitle(title) {
  useEffect(() => {
    document.title = `${title} · SkillMatch Admin`;
  }, [title]);
}
