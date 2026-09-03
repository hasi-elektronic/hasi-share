import { asset, type ImageAsset } from './images'

export type GalleryItem = {
  bild: ImageAsset
  titel: string
  bildunterschrift: string
  /** Steuert die Höhe in der Masonry-Spalte. */
  format: 'hoch' | 'quer' | 'quadrat'
}

export const GALLERY: GalleryItem[] = [
  {
    bild: asset('gal-01', 'Gedeckter Tisch mit Kerzen im abgedunkelten Gastraum', 1400, 1750),
    titel: 'Erster Gang',
    bildunterschrift: 'Der Raum, zwanzig Minuten vor dem Service.',
    format: 'hoch',
  },
  {
    bild: asset('gal-02', 'Offene Küche mit Kupfertöpfen im warmen Licht', 1400, 1050),
    titel: 'Am Pass',
    bildunterschrift: 'Vier Köche, zwölf Gäste, kein Zuruf.',
    format: 'quer',
  },
  {
    bild: asset('gal-03', 'Detailaufnahme eines angerichteten Gangs auf dunklem Keramikteller', 1400, 1400),
    titel: 'Handschrift',
    bildunterschrift: 'Drei Zutaten, die stimmen.',
    format: 'quadrat',
  },
  {
    bild: asset('gal-04', 'Weinflaschen und Gläser im Kellergewölbe', 1400, 1750),
    titel: 'Weinkeller',
    bildunterschrift: 'Vierhundert Positionen, achtzig davon aus Württemberg.',
    format: 'hoch',
  },
  {
    bild: asset('gal-05', 'Kerzenlicht spiegelt sich in einer schwarzen Steinplatte', 1400, 1050),
    titel: 'Kerzenlicht',
    bildunterschrift: 'Kein Deckenlicht nach 18 Uhr.',
    format: 'quer',
  },
  {
    bild: asset('gal-06', 'Hände beim Nachschenken eines Weißweins', 1400, 1400),
    titel: 'Begleitung',
    bildunterschrift: 'Sieben Gläser, jedes zur Hälfte gefüllt.',
    format: 'quadrat',
  },
  {
    bild: asset('gal-07', 'Chefs Table direkt an der Küchenzeile', 1400, 1750),
    titel: 'Chef’s Table',
    bildunterschrift: 'Zwei Plätze, direkt am Herd.',
    format: 'hoch',
  },
  {
    bild: asset('gal-08', 'Blick aus dem Fenster auf die nächtliche Königstraße', 1400, 1050),
    titel: 'Fensterplatz',
    bildunterschrift: 'Die Stadt läuft weiter, hier drinnen nicht.',
    format: 'quer',
  },
  {
    bild: asset('gal-09', 'Dessert mit Quitte und Sauerrahm in Nahaufnahme', 1400, 1400),
    titel: 'Zum Schluss',
    bildunterschrift: 'Mehr sauer als süß.',
    format: 'quadrat',
  },
]
