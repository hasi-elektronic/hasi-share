/** Stammdaten des (fiktiven) Hauses — einmal gepflegt, überall verwendet. */
export const HAUS = {
  name: 'NOIR — Fine Dining',
  strasse: 'Königstraße 12',
  plz: '70173',
  ort: 'Stuttgart',
  land: 'Deutschland',
  telefon: '+49 711 9028440',
  telefonHref: '+497119028440',
  email: 'reservierung@noir-stuttgart.de',
  inhaber: 'Elias Roth',
  ustId: 'DE 987 654 321',
  register: 'Einzelunternehmen, kein Handelsregistereintrag',
  aufsicht: 'Gaststättenerlaubnis: Stadt Stuttgart, Amt für öffentliche Ordnung',
} as const

export const OEFFNUNGSZEITEN = [
  { tage: 'Dienstag – Samstag', zeit: '18:00 – 24:00 Uhr' },
  { tage: 'Sonntag', zeit: '18:00 – 23:00 Uhr' },
  { tage: 'Montag', zeit: 'Ruhetag' },
] as const

export const STUDIO = {
  name: 'Hasi Site Studio',
  domain: 'hasi-elektronic.de',
  url: 'https://hasi-elektronic.de',
} as const
