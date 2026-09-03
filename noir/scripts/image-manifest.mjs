/**
 * Die Bildliste der Seite.
 *
 * `url` zeigt auf ein direktes Unsplash-Bild. So kommen Sie an eine solche
 * Adresse: Bild auf unsplash.com öffnen → Rechtsklick auf das Foto →
 * „Grafikadresse kopieren“. Die Adresse beginnt mit
 * https://images.unsplash.com/photo-…  — die Parameter dahinter setzt das
 * Skript selbst.
 *
 * Die Vorschläge unten sind ein Startpunkt. Tauschen Sie sie gegen eigene
 * Auswahl aus; scheitert ein Download, erzeugt das Skript automatisch ein
 * stimmungsgleiches Platzhalterbild und meldet es am Ende.
 *
 * `width`/`height` bestimmen das Seitenverhältnis im Layout (gegen Layout-
 * Sprünge). Die tatsächliche Datei wird immer in 640 / 1280 / 1920 px erzeugt.
 */

const U = (id) => `https://images.unsplash.com/photo-${id}`

export const IMAGES = [
  // --- Hero ---------------------------------------------------------------
  {
    name: 'hero-poster',
    width: 1920,
    height: 1200,
    hue: 34,
    url: U('1414235077428-338989a2e8c0'),
    note: 'Dunkler Gastraum, Kerzenlicht',
  },

  // --- Gänge --------------------------------------------------------------
  { name: 'dish-01', width: 1600, height: 2000, hue: 28, url: U('1559339352-11d035aa65de'), note: 'Auster / kalter Auftakt' },
  { name: 'dish-01v', width: 1600, height: 2000, hue: 96, url: U('1540189549336-e6e99c3679fe'), note: 'Kohlrabi vegetarisch' },
  { name: 'dish-02', width: 1600, height: 2000, hue: 20, url: U('1467003909585-2f8a72700288'), note: 'Saibling gebeizt' },
  { name: 'dish-02v', width: 1600, height: 2000, hue: 80, url: U('1518843875459-f738682238a6'), note: 'Sellerie im Salzteig' },
  { name: 'dish-03', width: 1600, height: 2000, hue: 38, url: U('1476124369491-e7addf5db371'), note: 'Alblinse mit Trüffel' },
  { name: 'dish-04', width: 1600, height: 2000, hue: 44, url: U('1495521821757-a1efb6729352'), note: 'Zwiebel aus der Glut' },
  { name: 'dish-05', width: 1600, height: 2000, hue: 4, url: U('1432139555190-58524dae6a55'), note: 'Reh mit Roter Bete' },
  { name: 'dish-05v', width: 1600, height: 2000, hue: 348, url: U('1512621776951-a57141f2eefd'), note: 'Rote Bete vegetarisch' },
  { name: 'dish-06', width: 1600, height: 2000, hue: 42, url: U('1488477181946-6428a0291777'), note: 'Quitte, Sauerrahm' },
  { name: 'dish-07', width: 1600, height: 2000, hue: 26, url: U('1509440159596-0249088772ff'), note: 'Kastanie, Kaffee' },

  // --- Galerie ------------------------------------------------------------
  { name: 'gal-01', width: 1400, height: 1750, hue: 32, url: U('1550966871-3ed3cdb5ed0c'), note: 'Gedeckter Tisch' },
  { name: 'gal-02', width: 1400, height: 1050, hue: 30, url: U('1556910103-1c02745aae4d'), note: 'Offene Küche' },
  { name: 'gal-03', width: 1400, height: 1400, hue: 36, url: U('1544025162-d76694265947'), note: 'Angerichteter Gang' },
  { name: 'gal-04', width: 1400, height: 1750, hue: 350, url: U('1510812431401-41d2bd2722f3'), note: 'Weinkeller' },
  { name: 'gal-05', width: 1400, height: 1050, hue: 34, url: U('1529543544282-ea669407fca3'), note: 'Kerzenlicht' },
  { name: 'gal-06', width: 1400, height: 1400, hue: 46, url: U('1510626176961-4b57d4fbad03'), note: 'Wein einschenken' },
  { name: 'gal-07', width: 1400, height: 1750, hue: 24, url: U('1466978913421-dad2ebd01d17'), note: 'Chefs Table' },
  { name: 'gal-08', width: 1400, height: 1050, hue: 210, url: U('1519671482749-fd09be7ccebf'), note: 'Fensterplatz bei Nacht' },
  { name: 'gal-09', width: 1400, height: 1400, hue: 40, url: U('1464349095431-e9a21285b5f3'), note: 'Dessert' },

  // --- Küchenchef ---------------------------------------------------------
  { name: 'chef-portrait', width: 1400, height: 1750, hue: 30, url: U('1583394293214-28a5b42f9fd0'), note: 'Porträt Küchenchef' },
  { name: 'chef-hands', width: 1400, height: 1050, hue: 34, url: U('1577219491135-ce391730fb2c'), note: 'Hände am Pass' },
]

/** Breiten, die erzeugt werden — muss zu IMAGE_WIDTHS in src/data/images.ts passen. */
export const WIDTHS = [640, 1280, 1920]
