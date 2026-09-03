export type Hotspot = {
  id: string
  titel: string
  text: string
  /** Weltposition im Raum [x, y, z]. */
  position: [number, number, number]
}

export const HOTSPOTS: Hotspot[] = [
  {
    id: 'chefs-table',
    titel: 'Chef’s Table',
    text: 'Zwei Plätze direkt an der Küchenzeile. Jeder Gang wird hier von der Person serviert, die ihn gekocht hat. Aufpreis 40 € pro Person.',
    position: [-2.7, 1.1, -1.6],
  },
  {
    id: 'weinkeller',
    titel: 'Weinkeller',
    text: 'Vierhundert Positionen im Gewölbe unter dem Gastraum, achtzig davon aus Württemberg. Nach dem Menü auf Anfrage zu besichtigen.',
    position: [2.9, 1.0, -2.4],
  },
  {
    id: 'fensterplatz',
    titel: 'Fensterplatz',
    text: 'Zwei Tische an der Fensterfront zur Königstraße. Beliebt im Winter, wenn die Scheiben beschlagen. Ohne Aufpreis, aber schnell vergeben.',
    position: [0.4, 1.05, 2.9],
  },
]
