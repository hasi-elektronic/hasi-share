import { asset } from './images'

export type Milestone = {
  jahr: string
  ort: string
  text: string
}

export const chefPortrait = asset(
  'chef-portrait',
  'Küchenchef Elias Roth in der offenen Küche des NOIR',
  1400,
  1750,
)

export const chefHands = asset(
  'chef-hands',
  'Hände beim Anrichten eines Gangs am Pass',
  1400,
  1050,
)

export const chef = {
  name: 'Elias Roth',
  rolle: 'Küchenchef & Inhaber',
  absaetze: [
    'Aufgewachsen ist Elias Roth in Bad Cannstatt, zwischen dem Gemüsestand seiner Großmutter und der Spätschicht seines Vaters. Gekocht wurde dort nicht aus Leidenschaft, sondern weil sieben Leute am Tisch saßen. Diese Selbstverständlichkeit hat er nie abgelegt.',
    'Nach der Lehre ging er nach Kopenhagen. Fünf Jahre lang hat er dort gelernt, dass ein Gericht nicht besser wird, wenn man etwas hinzufügt — sondern wenn man den Mut hat, etwas wegzulassen. Danach zwei Jahre Kyoto: Kaiseki, sieben Tage die Woche, und die Erkenntnis, dass Jahreszeit kein Marketingwort ist.',
    '2021 kam er zurück nach Stuttgart, in eine Stadt, die er lange als zu eng empfunden hatte. Das NOIR hat zwölf Plätze, eine offene Küche und keine Karte. Was auf den Teller kommt, entscheidet sich montags — am Ruhetag, wenn die Erzeuger anrufen.',
  ],
  zitat:
    'Ich brauche keine zwanzig Zutaten, um einen Abend zu tragen. Ich brauche drei, die stimmen.',
  milestones: [
    {
      jahr: '2006',
      ort: 'Fellbach',
      text: 'Lehre im Gasthof Hirsch. Drei Jahre Sauciers, Suppen und die Frage, warum man Fond nie mit dem Löffel probiert.',
    },
    {
      jahr: '2011',
      ort: 'Kopenhagen',
      text: 'Fünf Jahre in einer Küche, die Gemüse ernster nahm als Fleisch. Vom Commis zum Sous-Chef.',
    },
    {
      jahr: '2016',
      ort: 'Kyoto',
      text: 'Zwei Jahre Kaiseki im Stadtteil Higashiyama. Gelernt hat er dort vor allem, wie man wartet.',
    },
    {
      jahr: '2021',
      ort: 'Stuttgart',
      text: 'Eröffnung des NOIR mit zwölf Plätzen, offener Küche und einem einzigen Menü pro Abend.',
    },
  ] satisfies Milestone[],
} as const
