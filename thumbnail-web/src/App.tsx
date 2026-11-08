import './App.css'
import * as Icons from 'Icons'
import frame from './assets/frame.png'

const DEFAULT_HOME = 'DAL'
const DEFAULT_AWAY = 'CLE'
const DEFAULT_BACKGROUND = 'sample-bg.jpg'

// Change these values to adjust both logos without editing the layout rules.
const LOGO_SIZE = 396
const LOGO_MARGIN = 12

type Team = keyof typeof Icons

function teamFromParameter(value: string | null, fallback: Team): Team {
  const team = value?.toUpperCase() as Team | undefined
  return team && Object.prototype.hasOwnProperty.call(Icons, team) ? team : fallback
}

function App() {
  const params = new URLSearchParams(window.location.search)
  const home = teamFromParameter(params.get('home'), DEFAULT_HOME)
  const away = teamFromParameter(params.get('away'), DEFAULT_AWAY)
  const image = params.get('image')?.split('/').pop() || DEFAULT_BACKGROUND
  const background = `${import.meta.env.BASE_URL}${encodeURIComponent(image)}`
  const HomeLogo = Icons[home]
  const AwayLogo = Icons[away]

  return (
    <main className="thumbnail" style={{ '--logo-size': `${LOGO_SIZE}px`, '--logo-margin': `${LOGO_MARGIN}px` } as React.CSSProperties}>
      <img className="thumbnail__background" src={background} alt="" />
      <img className="thumbnail__frame" src={frame} alt="" />
      <div className="thumbnail__logo thumbnail__logo--home"><HomeLogo size={LOGO_SIZE} /></div>
      <div className="thumbnail__logo thumbnail__logo--away"><AwayLogo size={LOGO_SIZE} /></div>
    </main>
  )
}

export default App
