import type { Ctx } from "../http";
import { renderPage } from "./layout";

/** Last change of the policy text below (shown on the page). */
const UPDATED = "21. Oktober 2026";

/**
 * GET /privacy – German privacy policy (Datenschutzerklärung) for the store listings (Google Play requires a
 * reachable URL). Must describe what the apps and this Worker actually process; update it with every change
 * to licensing, accounts, sync or metadata.
 */
export function privacyPage(c: Ctx): Response {
  const app = c.env.APP_NAME || "NovaPlayer";
  const body = `
<h1>Datenschutzerklärung</h1>
<p class="muted">${app} von Hasi Elektronic · Stand: ${UPDATED}</p>

<div class="card">
<h2>1. Verantwortlicher</h2>
<p>Hamdi Güncavdi · Hasi Elektronic<br>Grabenstraße 18, 71665 Vaihingen an der Enz, Deutschland<br>
E-Mail: <a href="mailto:hguencavdi@gmail.com">hguencavdi@gmail.com</a></p>
</div>

<div class="card">
<h2>2. Kurzfassung</h2>
<p>${app} ist ein Player für IPTV-Dienste, die du selbst abonniert hast. Die App enthält <strong>keine Werbung,
kein Tracking und keine Analyse-Tools</strong>. Wir verkaufen keine Daten und geben sie nicht zu Werbezwecken weiter.
Deine IPTV-Zugangsdaten bleiben auf deinem Gerät.</p>
</div>

<div class="card">
<h2>3. Daten, die nur auf deinem Gerät bleiben</h2>
<p>Playlist-Adressen, Server, Benutzernamen und Passwörter deines IPTV-Anbieters werden ausschließlich lokal und
verschlüsselt gespeichert (Android Keystore bzw. Apple-Schlüsselbund). Senderlisten, Programmführer, Favoriten,
Wiedergabefortschritt und Einstellungen liegen ebenfalls lokal. Die App verbindet sich für Listen und Streams direkt
mit dem von dir eingetragenen Anbieter; wir erhalten diese Daten nicht. Für die Inhalte und den Datenschutz deines
IPTV-Anbieters ist allein dieser verantwortlich.</p>
</div>

<div class="card">
<h2>4. Film- und Serieninfos (TMDB)</h2>
<p>Poster, Beschreibungen, Bewertungen und Besetzung laden wir über unseren Server von The Movie Database (TMDB).
Dabei wird nur der <strong>Titel</strong> eines Films oder einer Serie (ggf. mit Jahr und Sprache) übertragen –
keine Zugangsdaten, keine Anbieter- oder Stream-Adressen und keine Gerätekennung. Unser Server fragt TMDB in eigenem
Namen ab; TMDB erhält deine IP-Adresse dabei nicht. Die Bilder selbst werden direkt von image.tmdb.org geladen, wobei
TMDB technisch bedingt deine IP-Adresse sieht. Diese App verwendet die TMDB-API, wird von TMDB jedoch weder
unterstützt noch zertifiziert.</p>
</div>

<div class="card">
<h2>5. Lizenzprüfung</h2>
<p>Damit ein Kauf oder Testzeitraum auf deinem Gerät gilt, sendet die App an unseren Server: eine pseudonyme
Gerätekennung (ein nicht umkehrbarer Hashwert, aus dem sich die Geräte-ID nicht ableiten lässt), Plattform,
App-Version sowie die Kauf-Belege von Google Play bzw. dem App Store. Wir prüfen diese Belege bei Google bzw. Apple
und speichern Kaufstatus und Testzeitraum zu dieser Kennung. Zahlungsdaten erhalten wir nie – die Zahlung wickeln
Google bzw. Apple ab. Rechtsgrundlage: Vertragserfüllung (Art. 6 Abs. 1 lit. b DSGVO).</p>
</div>

<div class="card">
<h2>6. Optionales Konto und Synchronisierung</h2>
<p>Ein Konto ist für die Nutzung nicht nötig. Wo die App eine Anmeldung anbietet und du sie nutzt, speichern wir
deine E-Mail-Adresse (für den Anmeldecode), Gerätenamen sowie Favoriten und Wiedergabefortschritt zum Abgleich
zwischen deinen Geräten – niemals IPTV-Zugangsdaten. Du kannst das Konto in der App jederzeit löschen; damit werden
diese Daten entfernt. Auf Apple-Geräten kann der Abgleich stattdessen über dein eigenes iCloud-Konto laufen (Apple).
Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO.</p>
</div>

<div class="card">
<h2>7. Server, Protokolle und Missbrauchsschutz</h2>
<p>Unser Server läuft bei Cloudflare, Inc. (Auftragsverarbeiter; Datenübermittlung in die USA auf Grundlage des
EU-US Data Privacy Framework bzw. von Standardvertragsklauseln). Beim Aufruf wird technisch deine IP-Adresse
verarbeitet. Zur Begrenzung von Anfragen speichern wir nur einen gekürzten Hashwert davon für wenige Minuten.
Fehlerprotokolle enthalten keine Zugangsdaten und werden nach kurzer Zeit gelöscht. Rechtsgrundlage: berechtigtes
Interesse am sicheren Betrieb (Art. 6 Abs. 1 lit. f DSGVO).</p>
</div>

<div class="card">
<h2>8. Speicherdauer</h2>
<p>Lizenzdaten speichern wir, solange die Lizenz besteht bzw. gesetzliche Aufbewahrungspflichten es verlangen.
Zwischengespeicherte Film- und Serieninfos enthalten keine personenbezogenen Daten und werden spätestens nach 90 Tagen
ohne Abruf gelöscht. Lokale Daten entfernst du durch Löschen der App.</p>
</div>

<div class="card">
<h2>9. Deine Rechte</h2>
<p>Du hast das Recht auf Auskunft, Berichtigung, Löschung, Einschränkung der Verarbeitung, Datenübertragbarkeit und
Widerspruch (Art. 15–21 DSGVO). Schreib uns dafür an <a href="mailto:hguencavdi@gmail.com">hguencavdi@gmail.com</a>.
Du kannst dich außerdem bei einer Datenschutz-Aufsichtsbehörde beschweren, z. B. beim Landesbeauftragten für den
Datenschutz und die Informationsfreiheit Baden-Württemberg.</p>
</div>

<div class="card">
<h2>10. Altersgrenze</h2>
<p>Die App richtet sich ausschließlich an Personen ab 18 Jahren. Wir erheben wissentlich keine Daten von
Minderjährigen.</p>
</div>

<div class="card">
<h2>11. Änderungen</h2>
<p>Wir passen diese Erklärung an, wenn sich die App ändert. Es gilt die jeweils hier veröffentlichte Fassung.</p>
</div>

<footer><a href="/terms">Nutzungsbedingungen</a> · © 2026 Hasi Elektronic</footer>`;
  const response = renderPage({ lang: "de", title: "Datenschutzerklärung", appName: app, body, scripts: [] });
  // Public, rarely changing: allow caching and search engines (the shared layout is no-store / noindex).
  response.headers.set("cache-control", "public, max-age=3600");
  return response;
}
