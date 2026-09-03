import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { PageTransition } from './PageTransition'

/** Gemeinsames Gerüst für Impressum und Datenschutz — ruhig, ohne Bewegung. */
export function LegalPage({
  titel,
  stand,
  children,
}: {
  titel: string
  stand: string
  children: ReactNode
}) {
  return (
    <PageTransition>
      <main id="inhalt" className="mx-auto w-full max-w-shell px-gutter pb-24 pt-32 sm:pt-40">
        <div className="max-w-[72ch]">
          <p className="border border-accent/40 bg-accent/5 px-5 py-4 text-sm text-ink">
            <strong className="font-medium text-accent">Demo-Inhalt.</strong> „NOIR — Fine Dining“
            ist ein erfundenes Restaurant. Alle Namen, Anschriften, Nummern und Kennungen auf dieser
            Seite sind frei erfunden und dienen ausschließlich der Veranschaulichung. Für ein
            echtes Haus sind diese Angaben vor Veröffentlichung vollständig zu ersetzen und
            rechtlich zu prüfen.
          </p>

          <h1 className="display mt-14 text-[clamp(2.5rem,7vw,4.5rem)]">{titel}</h1>
          <p className="label mt-6">Stand: {stand}</p>

          <div className="legal mt-14">{children}</div>

          <p className="mt-20 border-t border-hairline pt-8">
            <Link to="/" className="label link-underline hover:text-accent">
              ← Zurück zur Startseite
            </Link>
          </p>
        </div>
      </main>
    </PageTransition>
  )
}
