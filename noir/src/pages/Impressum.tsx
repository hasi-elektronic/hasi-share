import { Link } from 'react-router-dom'
import { LegalPage } from '@/components/LegalPage'
import { HAUS, STUDIO } from '@/data/haus'

export function Impressum() {
  return (
    <LegalPage titel="Impressum" stand="September 2026">
      <h2>Angaben gemäß § 5 DDG</h2>
      <p>
        {HAUS.name}
        <br />
        Inhaber: {HAUS.inhaber}
        <br />
        {HAUS.strasse}
        <br />
        {HAUS.plz} {HAUS.ort}
        <br />
        {HAUS.land}
      </p>
      <p>{HAUS.register}</p>

      <h2>Kontakt</h2>
      <dl>
        <dt>Telefon</dt>
        <dd>{HAUS.telefon}</dd>
        <dt>E-Mail</dt>
        <dd>{HAUS.email}</dd>
      </dl>

      <h2>Umsatzsteuer-Identifikationsnummer</h2>
      <p>
        Umsatzsteuer-Identifikationsnummer gemäß § 27 a Umsatzsteuergesetz:
        <br />
        {HAUS.ustId}
      </p>

      <h2>Zuständige Aufsichtsbehörde</h2>
      <p>
        {HAUS.aufsicht}
        <br />
        Eberhardstraße 39, 70173 Stuttgart
      </p>

      <h2>Redaktionell verantwortlich</h2>
      <p>
        {HAUS.inhaber}, Anschrift wie oben (§ 18 Abs. 2 Medienstaatsvertrag).
      </p>

      <h2>Verbraucherstreitbeilegung</h2>
      <p>
        Wir sind nicht bereit und nicht verpflichtet, an Streitbeilegungsverfahren vor einer
        Verbraucherschlichtungsstelle teilzunehmen (§ 36 Verbraucherstreitbeilegungsgesetz).
      </p>

      <h2>Haftung für Inhalte</h2>
      <p>
        Als Diensteanbieter sind wir gemäß § 7 Abs. 1 DDG für eigene Inhalte auf diesen Seiten nach
        den allgemeinen Gesetzen verantwortlich. Nach §§ 8 bis 10 DDG sind wir als Diensteanbieter
        jedoch nicht verpflichtet, übermittelte oder gespeicherte fremde Informationen zu überwachen
        oder nach Umständen zu forschen, die auf eine rechtswidrige Tätigkeit hinweisen.
      </p>
      <p>
        Verpflichtungen zur Entfernung oder Sperrung der Nutzung von Informationen nach den
        allgemeinen Gesetzen bleiben hiervon unberührt. Eine diesbezügliche Haftung ist jedoch erst
        ab dem Zeitpunkt der Kenntnis einer konkreten Rechtsverletzung möglich. Bei Bekanntwerden
        entsprechender Rechtsverletzungen entfernen wir diese Inhalte umgehend.
      </p>

      <h2>Haftung für Links</h2>
      <p>
        Unser Angebot enthält Links zu externen Websites Dritter, auf deren Inhalte wir keinen
        Einfluss haben. Deshalb können wir für diese fremden Inhalte auch keine Gewähr übernehmen.
        Für die Inhalte der verlinkten Seiten ist stets der jeweilige Anbieter oder Betreiber der
        Seiten verantwortlich. Die verlinkten Seiten wurden zum Zeitpunkt der Verlinkung auf
        mögliche Rechtsverstöße überprüft; rechtswidrige Inhalte waren nicht erkennbar.
      </p>

      <h2>Urheberrecht</h2>
      <p>
        Die durch die Seitenbetreiber erstellten Inhalte und Werke auf diesen Seiten unterliegen dem
        deutschen Urheberrecht. Die Vervielfältigung, Bearbeitung, Verbreitung und jede Art der
        Verwertung außerhalb der Grenzen des Urheberrechtes bedürfen der schriftlichen Zustimmung
        des jeweiligen Autors bzw. Erstellers. Downloads und Kopien dieser Seite sind nur für den
        privaten, nicht kommerziellen Gebrauch gestattet.
      </p>

      <h2>Gestaltung und technische Umsetzung</h2>
      <p>
        {STUDIO.name} —{' '}
        <a href={STUDIO.url} target="_blank" rel="noopener noreferrer">
          {STUDIO.domain}
        </a>
      </p>

      <h2>Datenschutz</h2>
      <p>
        Informationen zur Verarbeitung personenbezogener Daten finden Sie in unserer{' '}
        <Link to="/datenschutz">Datenschutzerklärung</Link>.
      </p>
    </LegalPage>
  )
}
