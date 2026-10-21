import type { Ctx } from "../http";
import { renderPage } from "./layout";

/** Last change of the terms text below (shown on the page). */
const UPDATED = "21. Oktober 2026";

/**
 * GET /terms – German terms of use (Nutzungsbedingungen) for the store listings and the apps' TERMS_URL.
 * Must match the real product: a player without own content, a free trial and a one-time lifetime purchase
 * through Google Play / the App Store.
 */
export function termsPage(c: Ctx): Response {
  const app = c.env.APP_NAME || "NovaPlayer";
  const body = `
<h1>Nutzungsbedingungen</h1>
<p class="muted">${app} von Hasi Elektronic · Stand: ${UPDATED}</p>

<div class="card">
<h2>1. Anbieter</h2>
<p>Hamdi Güncavdi · Hasi Elektronic<br>Grabenstraße 18, 71665 Vaihingen an der Enz, Deutschland<br>
E-Mail: <a href="mailto:hguencavdi@gmail.com">hguencavdi@gmail.com</a></p>
</div>

<div class="card">
<h2>2. Leistung</h2>
<p>${app} ist ein Medienplayer. Er spielt Inhalte ab, die du über eigene M3U-Playlists oder Xtream-Codes-Zugänge
deines IPTV-Anbieters einträgst. <strong>${app} stellt selbst keine Sender, Filme, Serien oder Playlists bereit</strong>
und verkauft oder vermittelt keine IPTV-Abonnements. Film- und Serieninfos stammen von The Movie Database (TMDB).</p>
</div>

<div class="card">
<h2>3. Altersgrenze</h2>
<p>Die Nutzung ist Personen ab 18 Jahren vorbehalten. Die App enthält eine optionale Kindersicherung (PIN) für
Inhalte deines Anbieters.</p>
</div>

<div class="card">
<h2>4. Deine Verantwortung für Inhalte</h2>
<p>Du darfst ${app} nur mit Playlists und Zugängen nutzen, zu deren Nutzung du berechtigt bist. Für Rechtmäßigkeit,
Verfügbarkeit und Qualität der Inhalte ist allein dein IPTV-Anbieter verantwortlich. Die Nutzung von Angeboten, die
Urheberrechte verletzen, ist untersagt.</p>
</div>

<div class="card">
<h2>5. Testzeitraum und Kauf</h2>
<p>Du kannst ${app} zunächst kostenlos testen. Danach ist für die weitere Wiedergabe ein einmaliger Kauf
(lebenslange Lizenz, kein Abo) nötig. Kauf, Zahlung, Erstattung und Familienfreigabe laufen ausschließlich über
Google Play bzw. den Apple App Store und deren Bedingungen. Der Preis wird vor dem Kauf im Store angezeigt.
Gesetzliche Widerrufs- und Gewährleistungsrechte bleiben unberührt.</p>
</div>

<div class="card">
<h2>6. Verfügbarkeit und Haftung</h2>
<p>Wir entwickeln ${app} sorgfältig, können aber nicht garantieren, dass jeder Stream oder jedes Format bei jedem
Anbieter funktioniert. Wir haften unbeschränkt bei Vorsatz und grober Fahrlässigkeit sowie bei Verletzung von Leben,
Körper oder Gesundheit; bei leichter Fahrlässigkeit nur für die Verletzung wesentlicher Vertragspflichten und
begrenzt auf den vorhersehbaren, typischen Schaden. Die Haftung nach dem Produkthaftungsgesetz bleibt unberührt.</p>
</div>

<div class="card">
<h2>7. Datenschutz</h2>
<p>Wie wir mit Daten umgehen, steht in der <a href="/privacy">Datenschutzerklärung</a>.</p>
</div>

<div class="card">
<h2>8. Änderungen und Recht</h2>
<p>Wir können diese Bedingungen anpassen, wenn sich die App ändert; es gilt die hier veröffentlichte Fassung. Es gilt
deutsches Recht; zwingende Verbraucherschutzvorschriften deines Wohnsitzlandes bleiben unberührt.</p>
</div>

<footer>© 2026 Hasi Elektronic</footer>`;
  const response = renderPage({ lang: "de", title: "Nutzungsbedingungen", appName: app, body, scripts: [] });
  response.headers.set("cache-control", "public, max-age=3600");
  return response;
}
