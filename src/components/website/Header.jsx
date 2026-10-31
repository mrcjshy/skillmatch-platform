import { useEffect, useRef, useState } from 'react'
import { ArrowUpRight, Menu, X } from 'lucide-react'
import { assets, hero, navigation } from '../../content/website'
export default function Header() {
  const [open, setOpen] = useState(false)
  const toggle = useRef(null)
  const header = useRef(null)
  useEffect(() => {
    if (!open) return
    const escape = (event) => {
      if (event.key === 'Escape') {
        setOpen(false)
        toggle.current?.focus()
      }
    }
    const outside = (event) => {
      if (!header.current?.contains(event.target)) setOpen(false)
    }
    const desktop = window.matchMedia('(min-width: 900px)')
    const resize = () => {
      if (desktop.matches) setOpen(false)
    }
    document.addEventListener('keydown', escape)
    document.addEventListener('pointerdown', outside)
    desktop.addEventListener('change', resize)
    return () => {
      document.removeEventListener('keydown', escape)
      document.removeEventListener('pointerdown', outside)
      desktop.removeEventListener('change', resize)
    }
  }, [open])
  return (
    <header className="site-header" ref={header}>
      <div className="container header-inner">
        <a href="#home" className="brand-link" aria-label="SkillMatch home">
          <img
            src={assets.BRAND_LOGO.src}
            alt=""
            width="36"
            height="36"
          />
          SkillMatch
        </a>
        <nav className="desktop-nav" aria-label="Main navigation">
          {navigation.map((link) => (
            <a key={link.href} href={link.href}>
              {link.label}
            </a>
          ))}
        </nav>
        <a href="#try" className="button button-small header-cta">
          {hero.action}
        </a>
        <button
          ref={toggle}
          className="menu-toggle"
          aria-label={open ? 'Close navigation' : 'Open navigation'}
          aria-expanded={open}
          aria-controls="mobile-navigation"
          type="button"
          onClick={() => setOpen(!open)}
        >
          {open ? <X /> : <Menu />}
        </button>
      </div>
      <nav
        id="mobile-navigation"
        className="mobile-nav"
        aria-label="Mobile navigation"
        hidden={!open}
      >
        {navigation.map((link) => (
          <a key={link.href} href={link.href} onClick={() => setOpen(false)}>
            {link.label}
            <ArrowUpRight size={18} aria-hidden="true" />
          </a>
        ))}
        <a href="#try" onClick={() => setOpen(false)}>
          {hero.action}
          <ArrowUpRight size={18} aria-hidden="true" />
        </a>
      </nav>
    </header>
  )
}
