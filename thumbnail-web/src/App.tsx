import './App.css'
import * as Icons from 'Icons'
import BrickHome from "./assets/brick-home.png"
import BrickAway from "./assets/brick-away.png"

const DEFAULT_HOME = 'DAL'
const DEFAULT_AWAY = 'CLE'
const DEFAULT_BACKGROUND = 'sample-bg.jpg'
const DEFAULT_DATE = 'Jan 1, 1970'

// Change these to adjust the centered date.
const DATE_FONT_FAMILY = 'Arial, sans-serif'
const DATE_FONT_SIZE = 64

// Change these values to adjust both logos without editing the layout rules.
const LOGO_SIZE = 396
const LOGO_HOME_TOP_MARGIN = 80
const LOGO_HOME_LEFT_MARGIN = 30
const LOGO_AWAY_TOP_MARGIN = 80
const LOGO_AWAY_RIGHT_MARGIN = 30
const BRICK_HOME_BOTTOM_MARGIN = 120
const BRICK_HOME_LEFT_MARGIN = 12
const BRICK_AWAY_BOTTOM_MARGIN = 120
const BRICK_AWAY_RIGHT_MARGIN = 24

type Team = keyof typeof Icons

function teamFromParameter(value: string | null, fallback: Team): Team {
    const team = value?.toUpperCase() as Team | undefined
    return team && Object.prototype.hasOwnProperty.call(Icons, team) ? team : fallback
}

function App() {
    const params = new URLSearchParams(window.location.search)
    const home = teamFromParameter(params.get('home'), DEFAULT_HOME)
    const away = teamFromParameter(params.get('away'), DEFAULT_AWAY)
    const date = params.get('date') || DEFAULT_DATE
    const image = params.get('image')?.split('/').pop() || DEFAULT_BACKGROUND
    const background = image === 'background.jpg' ? '/background.jpg' : `${import.meta.env.BASE_URL}${encodeURIComponent(image)}`
    const HomeLogo = Icons[home]
    const AwayLogo = Icons[away]

    return (
        <main className="thumbnail" style={{
            '--logo-size': `${LOGO_SIZE}px`,
            '--logo-home-top-margin': `${LOGO_HOME_TOP_MARGIN}px`,
            '--logo-home-left-margin': `${LOGO_HOME_LEFT_MARGIN}px`,
            '--logo-away-top-margin': `${LOGO_AWAY_TOP_MARGIN}px`,
            '--logo-away-right-margin': `${LOGO_AWAY_RIGHT_MARGIN}px`,
            '--brick-home-bottom-margin': `${BRICK_HOME_BOTTOM_MARGIN}px`,
            '--brick-home-left-margin': `${BRICK_HOME_LEFT_MARGIN}px`,
            '--brick-away-bottom-margin': `${BRICK_AWAY_BOTTOM_MARGIN}px`,
            '--brick-away-right-margin': `${BRICK_AWAY_RIGHT_MARGIN}px`,
            '--date-font-family': DATE_FONT_FAMILY,
            '--date-font-size': `${DATE_FONT_SIZE}px`
        } as React.CSSProperties}>
            <img className="thumbnail__background" src={background} alt=""/>
            <div className="thumbnail__logo thumbnail__logo--home"><HomeLogo size={LOGO_SIZE}/></div>
            <div className="thumbnail__logo thumbnail__logo--away"><AwayLogo size={LOGO_SIZE}/></div>

            <img className="thumbnail__brick thumbnail__brick--home" src={BrickHome} alt=""/>
            <img className="thumbnail__brick thumbnail__brick--away" src={BrickAway} alt=""/>

            <div className="left-shade"></div>
            <div className="right-shade"></div>
            <div className="thumbnail__date">{date}</div>
        </main>
    )
}

export default App
