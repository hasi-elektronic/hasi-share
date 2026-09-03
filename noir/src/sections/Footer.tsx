import { useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import { Wordmark } from '@/components/Wordmark'
import { HAUS, OEFFNUNGSZEITEN, STUDIO } from '@/data/haus'

export function Footer() {
  const [newsletterHinweis, setNewsletterHinweis] = useState(false)

  // Der Verteiler ist Teil der Schaustellung — hier wird nichts verschickt.
  const onNewsletter = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setNewsletterHinweis(true)
  }

  return (
    <footer className="border-t border-hairline bg-bg">
      <div className="mx-auto w-full max-w-shell px-gutter py-20 sm:py-24">
        <div className="grid gap-14 lg:grid-cols-12">
          {/* Marke + Anschrift */}
          <div className="lg:col-span-4">
            <Wordmark withSub />
            <address className="mt-10 not-italic leading-relaxed text-muted">
              {HAUS.strasse}
              <br />
              {HAUS.plz} {HAUS.ort}
              <br />
              <a href={`tel:${HAUS.telefonHref}`} className="link-underline mt-4 inline-block text-ink">
                {HAUS.telefon}
              </a>
              <br />
              <a href={`mailto:${HAUS.email}`} className="link-underline text-ink">
                {HAUS.email}
              </a>
            </address>
          </div>

          {/* Öffnungszeiten */}
          <div className="lg:col-span-3">
            <h2 className="label label-accent">Öffnungszeiten</h2>
            <dl className="mt-8 space-y-4 text-sm">
              {OEFFNUNGSZEITEN.map((zeile) => (
                <div key={zeile.tage}>
                  <dt className="text-ink">{zeile.tage}</dt>
                  <dd className="text-muted">{zeile.zeit}</dd>
                </div>
              ))}
            </dl>
            <p className="mt-6 text-xs text-muted">
              Der Service beginnt für alle Gäste um 19 Uhr.
            </p>
          </div>

          {/* Verteiler + soziale Kanäle */}
          <div className="lg:col-span-5">
            <h2 className="label label-accent">Zwischen den Menüs</h2>
            <p className="mt-8 max-w-[42ch] text-sm text-muted">
              Sieben Mal im Jahr schreiben wir, was sich in der Küche ändert. Keine Angebote, kein
              Newsletter im üblichen Sinn.
            </p>

            <form onSubmit={onNewsletter} className="mt-8 flex flex-wrap items-end gap-4">
              <div className="min-w-[16rem] flex-1">
                <label htmlFor="newsletter" className="label block">
                  E-Mail
                </label>
                <input
                  id="newsletter"
                  type="email"
                  autoComplete="email"
                  placeholder="name@beispiel.de"
                  className="mt-3 w-full border-0 border-b border-hairline bg-transparent px-0 py-3 text-ink outline-none transition-colors duration-500 ease-noir placeholder:text-muted/60 focus:border-accent"
                />
              </div>
              <button
                type="submit"
                data-cursor="Eintragen"
                className="border border-hairline px-6 py-3 text-[0.7rem] uppercase tracking-label text-ink transition-colors duration-500 ease-noir hover:border-accent hover:text-accent"
              >
                Eintragen
              </button>
            </form>
            <p className="mt-3 text-xs text-muted" role="status">
              {newsletterHinweis
                ? 'Demo-Inhalt: Es wurde nichts gespeichert und nichts versendet.'
                : 'Demo-Inhalt — der Verteiler ist in dieser Schaustellung ohne Funktion.'}
            </p>

            <ul className="mt-10 flex items-center gap-4">
              {[
                { name: 'Instagram', pfad: 'instagram' },
                { name: 'Google', pfad: 'google' },
              ].map((kanal) => (
                <li key={kanal.name}>
                  {/*
                    Bewusst kein <a href>: die Profile existieren nicht. Ein toter
                    Link wäre für Screenreader schlimmer als ein deaktivierter.
                  */}
                  <span
                    role="link"
                    aria-disabled="true"
                    title={`${kanal.name} — in dieser Demo ohne Ziel`}
                    className="flex h-11 w-11 cursor-not-allowed items-center justify-center border border-hairline text-muted"
                  >
                    <span className="sr-only">{kanal.name} (in dieser Demo ohne Ziel)</span>
                    <SocialIcon name={kanal.pfad} />
                  </span>
                </li>
              ))}
            </ul>
          </div>
        </div>

        {/* Fußzeile */}
        <div className="mt-16 flex flex-col gap-6 border-t border-hairline pt-8 sm:flex-row sm:items-center sm:justify-between">
          <ul className="flex flex-wrap gap-x-8 gap-y-2">
            <li>
              <Link to="/impressum" className="label link-underline hover:text-ink">
                Impressum
              </Link>
            </li>
            <li>
              <Link to="/datenschutz" className="label link-underline hover:text-ink">
                Datenschutz
              </Link>
            </li>
            <li>
              <span className="label">© {new Date().getFullYear()} {HAUS.name}</span>
            </li>
          </ul>

          <p className="text-xs text-muted">
            Website:{' '}
            <a
              href={STUDIO.url}
              rel="noopener noreferrer"
              target="_blank"
              className="link-underline text-ink"
            >
              {STUDIO.name} — {STUDIO.domain}
            </a>
          </p>
        </div>
      </div>
    </footer>
  )
}

function SocialIcon({ name }: { name: string }) {
  if (name === 'instagram') {
    return (
      <svg viewBox="0 0 24 24" aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.2">
        <rect x="3" y="3" width="18" height="18" rx="5" />
        <circle cx="12" cy="12" r="4" />
        <circle cx="17.2" cy="6.8" r="0.9" fill="currentColor" stroke="none" />
      </svg>
    )
  }
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.2">
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7.5v9M7.5 12h9" />
    </svg>
  )
}
