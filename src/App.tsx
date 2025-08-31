import { useEffect, useState } from 'react'
import Home from './app/home'
import Importer from './app/importer'
import Settings from './app/settings'
import Lesson from './app/lesson'

import './App.css'

function App() {
  const [route, setRoute] = useState(() => window.location.hash.slice(1) || 'home')
  const [theme, setTheme] = useState<'dark' | 'light'>('dark')

  useEffect(() => {
    const onHashChange = () => setRoute(window.location.hash.slice(1) || 'home')
    window.addEventListener('hashchange', onHashChange)
    return () => window.removeEventListener('hashchange', onHashChange)
  }, [])

  useEffect(() => {
    document.body.setAttribute('data-theme', theme)
  }, [theme])

  const navigate = (to: string) => {
    window.location.hash = to
  }

  let page
  if (route.startsWith('lesson/')) {
    const id = route.split('/')[1]
    page = <Lesson id={id} />
  } else {
    switch (route) {
      case 'importer':
        page = <Importer />
        break
      case 'settings':
        page = <Settings />
        break
      default:
        page = <Home />
    }
  }

  return (
    <div className="app">
      <header>
        <span>Learn English</span>
        <button onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}>
          {theme === 'dark' ? 'Light' : 'Dark'}
        </button>
      </header>
      <main>{page}</main>
      <nav className="bottom-nav">
        <button className={route === 'home' ? 'active' : ''} onClick={() => navigate('home')}>
          Home
        </button>
        <button
          className={route === 'importer' ? 'active' : ''}
          onClick={() => navigate('importer')}
        >
          Importer
        </button>
        <button
          className={route === 'settings' ? 'active' : ''}
          onClick={() => navigate('settings')}
        >
          Settings
        </button>
      </nav>
    </div>
  )
}

export default App
