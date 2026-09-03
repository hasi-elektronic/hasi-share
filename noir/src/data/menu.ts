import { asset, type ImageAsset } from './images'

export type Course = {
  /** Gangnummer, zweistellig — wird als Messingziffer gesetzt. */
  nummer: string
  name: string
  beschreibung: string
  /** Erzeuger oder Herkunft, eine Zeile. */
  herkunft: string
  weinbegleitung: string
  bild: ImageAsset
}

export type MenuCourse = {
  klassisch: Course
  /** Nur gesetzt, wenn dieser Gang für das vegetarische Menü getauscht wird. */
  vegetarisch?: Course
}

export const MENU_PRICE = {
  menue: '185 €',
  weinbegleitung: '+ 95 €',
  alkoholfrei: '+ 65 €',
} as const

export const MENU: MenuCourse[] = [
  {
    klassisch: {
      nummer: '01',
      name: 'Auster, Holunder, Gurke',
      beschreibung:
        'Roh serviert, mit einem klaren Sud aus Holunderblüte und geeister Gurke. Ein kalter Auftakt, der den Gaumen öffnet.',
      herkunft: 'Austernkompanie List · Sylt',
      weinbegleitung: 'Riesling Kabinett trocken, Weingut Aldinger, Fellbach 2023',
      bild: asset('dish-01', 'Auster mit Holundersud und geeister Gurke auf schwarzem Stein', 1600, 2000),
    },
    vegetarisch: {
      nummer: '01',
      name: 'Kohlrabi, Holunder, Gurke',
      beschreibung:
        'Hauchdünn gehobelter Kohlrabi im Holundersud, geeiste Gurke, ein Tropfen Kernöl. Derselbe kalte Auftakt, ohne Meer.',
      herkunft: 'Gärtnerei Maier · Filderstadt',
      weinbegleitung: 'Riesling Kabinett trocken, Weingut Aldinger, Fellbach 2023',
      bild: asset('dish-01v', 'Dünn gehobelter Kohlrabi mit Holundersud auf schwarzem Teller', 1600, 2000),
    },
  },
  {
    klassisch: {
      nummer: '02',
      name: 'Saibling, Buttermilch, Dill',
      beschreibung:
        'Zwei Stunden gebeizt, danach nur noch handwarm. Buttermilch aus Rohmilch, Dillöl, geröstete Roggenkrume.',
      herkunft: 'Forellenhof Aulendorf · Oberschwaben',
      weinbegleitung: 'Weißburgunder vom Muschelkalk, Weingut Wöhrwag, Untertürkheim 2022',
      bild: asset('dish-02', 'Gebeizter Saibling mit Buttermilch und Dillöl', 1600, 2000),
    },
    vegetarisch: {
      nummer: '02',
      name: 'Junger Sellerie, Buttermilch, Dill',
      beschreibung:
        'Im Salzteig gegart, aufgebrochen am Tisch. Buttermilch aus Rohmilch, Dillöl, geröstete Roggenkrume.',
      herkunft: 'Hof Kienzle · Schwäbische Alb',
      weinbegleitung: 'Weißburgunder vom Muschelkalk, Weingut Wöhrwag, Untertürkheim 2022',
      bild: asset('dish-02v', 'Im Salzteig gegarter Sellerie mit Buttermilch', 1600, 2000),
    },
  },
  {
    klassisch: {
      nummer: '03',
      name: 'Alblinse, Wachtelei, Trüffel',
      beschreibung:
        'Linsen, zwölf Stunden im eigenen Fond. Darüber ein konfiertes Wachtelei und so viel Herbsttrüffel, wie der Tag hergibt.',
      herkunft: 'Lauteracher Alb-Feld-Früchte · Münsingen',
      weinbegleitung: 'Chardonnay im Holzfass, Weingut Zaiß, Stuttgart-Uhlbach 2021',
      bild: asset('dish-03', 'Alblinsen mit konfiertem Wachtelei und gehobeltem Trüffel', 1600, 2000),
    },
  },
  {
    klassisch: {
      nummer: '04',
      name: 'Zwiebel, Heu, Bergkäse',
      beschreibung:
        'Sechs Stunden in der Glut, dann im Heurauch. Innen fast flüssig, dazu gereifter Bergkäse und Kerbel.',
      herkunft: 'Demeter-Hof Häussler · Filderebene',
      weinbegleitung: 'Trollinger alte Reben, Weingut Kuhnle, Weinstadt 2022',
      bild: asset('dish-04', 'In der Glut gegarte Zwiebel mit gehobeltem Bergkäse', 1600, 2000),
    },
  },
  {
    klassisch: {
      nummer: '05',
      name: 'Reh, Rote Bete, Wacholder',
      beschreibung:
        'Rücken am Knochen gebraten, zwei Wochen abgehangen. Rote Bete aus der Asche, Wacholderjus, ein Hauch Tannennadel.',
      herkunft: 'Revier Schönbuch · Landkreis Böblingen',
      weinbegleitung: 'Lemberger Großes Gewächs, Weingut Rainer Schnaitmann, Fellbach 2020',
      bild: asset('dish-05', 'Rehrücken mit Roter Bete und Wacholderjus', 1600, 2000),
    },
    vegetarisch: {
      nummer: '05',
      name: 'Rote Bete, Pflaume, Wacholder',
      beschreibung:
        'Ganze Knollen in der Asche vergraben, danach in Pflaumenessig lackiert. Wacholderjus, ein Hauch Tannennadel.',
      herkunft: 'Demeter-Hof Häussler · Filderebene',
      weinbegleitung: 'Lemberger Großes Gewächs, Weingut Rainer Schnaitmann, Fellbach 2020',
      bild: asset('dish-05v', 'In Asche gegarte Rote Bete mit Pflaumenlack', 1600, 2000),
    },
  },
  {
    klassisch: {
      nummer: '06',
      name: 'Quitte, Sauerrahm, Vogelbeere',
      beschreibung:
        'Quitte aus dem eigenen Ansatz vom Vorjahr, Sauerrahm-Eis, eingelegte Vogelbeeren. Mehr sauer als süß.',
      herkunft: 'Streuobstwiese Beutelsbach · Remstal',
      weinbegleitung: 'Gewürztraminer Spätlese, Weingut Karl Haidle, Kernen 2021',
      bild: asset('dish-06', 'Quittendessert mit Sauerrahm-Eis und Vogelbeeren', 1600, 2000),
    },
  },
  {
    klassisch: {
      nummer: '07',
      name: 'Kastanie, Kaffee, Salz',
      beschreibung:
        'Der letzte Gang kommt ohne Teller: eine warme Kastanienpraline, dunkler Kaffee, Fleur de Sel. Dann ist der Abend zu Ende.',
      herkunft: 'Röstwerk Heslach · Stuttgart',
      weinbegleitung: 'Alter Trester aus dem Remstal, Fassstärke',
      bild: asset('dish-07', 'Warme Kastanienpraline mit Kaffee und Fleur de Sel', 1600, 2000),
    },
  },
]

/** Liefert die 7 Gänge in der gewünschten Fassung. */
export function coursesFor(vegetarian: boolean): Course[] {
  return MENU.map((course) => (vegetarian && course.vegetarisch ? course.vegetarisch : course.klassisch))
}

/** Wie viele Gänge im vegetarischen Menü getauscht werden. */
export const VEGETARIAN_SWAPS = MENU.filter((course) => course.vegetarisch).length
