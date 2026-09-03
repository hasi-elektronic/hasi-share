export type ManifestStatement = {
  /** "|" erzwingt einen Zeilenumbruch. */
  text: string
  caption: string
}

export const MANIFEST: ManifestStatement[] = [
  {
    text: 'Sieben Gänge.|Ein Abend.|Keine Ablenkung.',
    caption: 'Ein Menü, kein à la carte. Beginn für alle Gäste um 19 Uhr.',
  },
  {
    text: 'Zwölf Plätze.|Eine offene Küche.|Kein zweiter Durchgang.',
    caption: 'Wir kochen für den Raum, nicht für die Auslastung.',
  },
  {
    text: 'Was reif ist,|kommt auf den Teller.|Sonst nichts.',
    caption: 'Sechs Erzeuger zwischen Filder, Alb und Bodensee. Wöchentlich neu.',
  },
]
