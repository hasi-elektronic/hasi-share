import { Link } from 'react-router-dom'
import { LegalPage } from '@/components/LegalPage'
import { HAUS } from '@/data/haus'

export function Datenschutz() {
  return (
    <LegalPage titel="Datenschutzerklärung" stand="September 2026">
      <h2>1. Verantwortlicher</h2>
      <p>
        Verantwortlich für die Datenverarbeitung auf dieser Website im Sinne von Art. 4 Nr. 7 DSGVO
        ist:
      </p>
      <p>
        {HAUS.name}
        <br />
        Inhaber: {HAUS.inhaber}
        <br />
        {HAUS.strasse}, {HAUS.plz} {HAUS.ort}
        <br />
        Telefon: {HAUS.telefon}
        <br />
        E-Mail: {HAUS.email}
      </p>
      <p>
        Ein Datenschutzbeauftragter ist nicht bestellt, da die gesetzlichen Voraussetzungen des
        § 38 BDSG nicht vorliegen.
      </p>

      <h2>2. Hosting und Server-Protokolle</h2>
      <p>
        Diese Website wird bei der Cloudflare Germany GmbH (Rosenthaler Straße 51, 10178 Berlin) auf
        der Plattform <strong>Cloudflare Pages</strong> gehostet. Beim Aufruf der Seiten verarbeitet
        Cloudflare als Auftragsverarbeiter technisch notwendige Verbindungsdaten:
      </p>
      <ul>
        <li>gekürzte IP-Adresse der anfragenden Stelle</li>
        <li>Datum und Uhrzeit des Zugriffs</li>
        <li>Name und Größe der abgerufenen Datei</li>
        <li>übertragene Datenmenge und HTTP-Statuscode</li>
        <li>Browsertyp und Betriebssystem (User-Agent)</li>
      </ul>
      <p>
        Rechtsgrundlage ist Art. 6 Abs. 1 lit. f DSGVO. Das berechtigte Interesse liegt im sicheren
        und störungsfreien Betrieb der Website. Es besteht ein Auftragsverarbeitungsvertrag nach
        Art. 28 DSGVO. Soweit Daten außerhalb der EU verarbeitet werden, geschieht dies auf
        Grundlage der EU-Standardvertragsklauseln. Die Protokolle werden nach spätestens sieben
        Tagen gelöscht.
      </p>

      <h2>3. Reservierungsanfragen</h2>
      <p>
        Wenn Sie das Reservierungsformular nutzen, verarbeiten wir die von Ihnen angegebenen Daten:
        Name, E-Mail-Adresse, Telefonnummer, gewünschtes Datum, gewünschte Uhrzeit, Personenzahl
        sowie freiwillige Angaben zu Anlass und Nachricht.
      </p>
      <p>
        Rechtsgrundlage ist Art. 6 Abs. 1 lit. b DSGVO (Durchführung vorvertraglicher Maßnahmen auf
        Ihre Anfrage). Ohne diese Angaben können wir Ihre Anfrage nicht bearbeiten. Die Daten werden
        ausschließlich zur Bearbeitung Ihrer Reservierung verwendet und nicht zu Werbezwecken
        genutzt.
      </p>
      <p>
        <strong>Hinweis zur Demo:</strong> In dieser Schaustellung wird keine Reservierung
        gespeichert und keine E-Mail versendet. Die Anfrage wird von einer Cloudflare-Pages-Function
        entgegengenommen, geprüft und verworfen. Im Produktivbetrieb würden die Daten an das
        Reservierungspostfach des Hauses weitergeleitet und dort nach Abschluss des Besuchs
        beziehungsweise nach Ablauf gesetzlicher Aufbewahrungsfristen gelöscht.
      </p>

      <h3>Schutz vor automatisierten Anfragen</h3>
      <p>
        Das Formular enthält ein für Menschen unsichtbares Feld („Honeypot“), das ausschließlich der
        Erkennung automatisierter Einsendungen dient. Es werden dabei keine personenbezogenen Daten
        zusätzlich erhoben. Eine Einbindung von Cloudflare Turnstile ist technisch vorbereitet, in
        dieser Demo jedoch <strong>nicht aktiviert</strong>.
      </p>

      <h2>4. Cookies, Analyse und Speicherung im Browser</h2>
      <p>
        Diese Website setzt <strong>keine Cookies</strong>, keine Analyse- oder Trackingdienste,
        keine Werbenetzwerke und keine sozialen Plugins ein. Es findet keine Profilbildung statt.
      </p>
      <p>
        Verwendet wird ausschließlich der <strong>sessionStorage</strong> Ihres Browsers mit einem
        einzigen technischen Eintrag („noir:intro-seen“). Er merkt sich, ob die Startanimation in
        dieser Sitzung bereits gelaufen ist, damit sie beim Zurückkehren nicht erneut abgespielt
        wird. Dieser Eintrag enthält keine personenbezogenen Daten, wird nicht an uns übertragen und
        vom Browser beim Schließen des Tabs automatisch gelöscht. Rechtsgrundlage: § 25 Abs. 2 Nr. 2
        TDDDG (unbedingt erforderlich für den ausdrücklich gewünschten Dienst).
      </p>

      <h2>5. Schriften und externe Inhalte</h2>
      <p>
        Die verwendeten Schriftarten (Cormorant Garamond und Inter) werden lokal von unserem Server
        ausgeliefert. Es besteht <strong>keine Verbindung zu Google Fonts</strong> oder anderen
        Drittanbietern. Auch Karten, Videos und Schaltflächen sozialer Netzwerke werden nicht
        eingebunden; die 3-D-Darstellungen werden vollständig im Browser berechnet.
      </p>

      <h2>6. SSL- beziehungsweise TLS-Verschlüsselung</h2>
      <p>
        Diese Seite nutzt aus Sicherheitsgründen eine TLS-Verschlüsselung. Eine verschlüsselte
        Verbindung erkennen Sie an „https://“ in der Adresszeile Ihres Browsers. Ist sie aktiv,
        können die Daten, die Sie an uns übermitteln, nicht von Dritten mitgelesen werden.
      </p>

      <h2>7. Speicherdauer</h2>
      <p>
        Wir verarbeiten personenbezogene Daten nur so lange, wie es für den jeweiligen Zweck
        erforderlich ist. Reservierungsdaten werden nach dem Besuch gelöscht, sofern keine
        handels- oder steuerrechtlichen Aufbewahrungsfristen entgegenstehen. Server-Protokolle
        werden nach spätestens sieben Tagen gelöscht.
      </p>

      <h2>8. Ihre Rechte</h2>
      <p>Ihnen stehen gegenüber uns folgende Rechte hinsichtlich Ihrer personenbezogenen Daten zu:</p>
      <ul>
        <li>Auskunft über die verarbeiteten Daten (Art. 15 DSGVO)</li>
        <li>Berichtigung unrichtiger Daten (Art. 16 DSGVO)</li>
        <li>Löschung (Art. 17 DSGVO)</li>
        <li>Einschränkung der Verarbeitung (Art. 18 DSGVO)</li>
        <li>Datenübertragbarkeit (Art. 20 DSGVO)</li>
        <li>Widerspruch gegen die Verarbeitung (Art. 21 DSGVO)</li>
        <li>Widerruf einer erteilten Einwilligung mit Wirkung für die Zukunft (Art. 7 Abs. 3 DSGVO)</li>
      </ul>
      <p>
        Zur Ausübung genügt eine formlose Nachricht an {HAUS.email}. Unabhängig davon steht Ihnen
        ein Beschwerderecht bei einer Aufsichtsbehörde zu (Art. 77 DSGVO). Zuständig ist der
        Landesbeauftragte für den Datenschutz und die Informationsfreiheit Baden-Württemberg,
        Lautenschlagerstraße 20, 70173 Stuttgart.
      </p>

      <h2>9. Änderungen dieser Erklärung</h2>
      <p>
        Wir passen diese Datenschutzerklärung an, sobald sich die Rechtslage oder die auf dieser
        Website eingesetzte Technik ändert. Es gilt jeweils die hier abrufbare Fassung. Das{' '}
        <Link to="/impressum">Impressum</Link> nennt die verantwortliche Stelle.
      </p>
    </LegalPage>
  )
}
