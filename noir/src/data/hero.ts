import { asset } from './images'

/** Standbild für Geräte ohne WebGL2 und bei reduzierter Bewegung. */
export const heroPoster = asset(
  'hero-poster',
  'Dunkel gedeckter Tisch im NOIR, ein schwarzer Keramikteller im Kerzenlicht',
  1920,
  1200,
)

export const heroCopy = {
  eyebrow: 'NOIR — Fine Dining · Stuttgart',
  headline: 'Die Stille vor|dem ersten Gang.',
  lead: 'Sieben Gänge, ein Abend, zwölf Plätze. Wir kochen mit dem, was die Woche hergibt — und lassen alles andere weg.',
} as const
