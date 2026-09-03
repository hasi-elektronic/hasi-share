import { Link } from 'react-router-dom'
import { PageTransition } from '@/components/PageTransition'

export function NotFound() {
  return (
    <PageTransition>
      <main
        id="inhalt"
        className="mx-auto flex min-h-[70svh] w-full max-w-shell flex-col justify-center px-gutter pb-24 pt-40"
      >
        <p className="label label-accent">Fehler 404</p>
        <h1 className="display mt-8 text-[clamp(3rem,10vw,7rem)]">Dieser Gang steht nicht auf der Karte.</h1>
        <p className="mt-8 max-w-[46ch] text-muted">
          Die gewünschte Seite gibt es nicht. Vielleicht wurde sie verschoben — oder sie war nie
          da. Zurück an den Anfang:
        </p>
        <p className="mt-10">
          <Link to="/" data-cursor="Start" className="label link-underline text-accent">
            → Zur Startseite
          </Link>
        </p>
      </main>
    </PageTransition>
  )
}
