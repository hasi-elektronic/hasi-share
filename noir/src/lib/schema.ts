import { z } from 'zod'

/**
 * Reservierungs-Schema. Wird von der Client-Validierung UND von der
 * Cloudflare-Pages-Function benutzt — eine Quelle, zwei Laufzeiten.
 * Deshalb hier bewusst keine DOM- oder Node-Abhängigkeiten.
 */

export const RESERVATION_TIMES = ['18:00', '18:30', '19:00', '19:30', '20:00', '20:30'] as const
export type ReservationTime = (typeof RESERVATION_TIMES)[number]

export const OCCASIONS = ['keiner', 'geburtstag', 'jahrestag', 'geschaeftlich', 'antrag'] as const
export type Occasion = (typeof OCCASIONS)[number]

export const OCCASION_LABELS: Record<Occasion, string> = {
  keiner: 'Kein besonderer Anlass',
  geburtstag: 'Geburtstag',
  jahrestag: 'Jahrestag',
  geschaeftlich: 'Geschäftsessen',
  antrag: 'Heiratsantrag',
}

export const MIN_GUESTS = 2
export const MAX_GUESTS = 8

/** Montag ist Ruhetag (0 = Sonntag … 6 = Samstag). */
export const CLOSED_WEEKDAY = 1

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/

/** Heutiges Datum in Stuttgarter Zeit — Server und Browser sehen denselben Tag. */
export function todayInBerlin(): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Europe/Berlin',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date())
}

/** true, wenn das ISO-Datum auf den Ruhetag fällt. */
export function isClosedDay(isoDate: string): boolean {
  if (!ISO_DATE.test(isoDate)) return false
  const date = new Date(`${isoDate}T12:00:00Z`)
  if (Number.isNaN(date.getTime())) return false
  return date.getUTCDay() === CLOSED_WEEKDAY
}

/** Menschenlesbares Datum, z. B. "Freitag, 12. Juni 2026". */
export function formatGermanDate(isoDate: string): string {
  const date = new Date(`${isoDate}T12:00:00Z`)
  if (Number.isNaN(date.getTime())) return isoDate
  return new Intl.DateTimeFormat('de-DE', {
    timeZone: 'Europe/Berlin',
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  }).format(date)
}

export const reservationSchema = z.object({
  datum: z
    .string({ required_error: 'Bitte wählen Sie ein Datum.' })
    .regex(ISO_DATE, 'Bitte wählen Sie ein gültiges Datum.')
    .refine((value) => value >= todayInBerlin(), 'Bitte wählen Sie ein Datum ab heute.')
    .refine((value) => !isClosedDay(value), 'Montags ist Ruhetag — bitte wählen Sie einen anderen Tag.'),

  uhrzeit: z.enum(RESERVATION_TIMES, {
    errorMap: () => ({ message: 'Bitte wählen Sie eine Uhrzeit.' }),
  }),

  personen: z
    .number({ invalid_type_error: 'Bitte geben Sie die Personenzahl an.' })
    .int()
    .min(MIN_GUESTS, `Wir reservieren ab ${MIN_GUESTS} Personen.`)
    .max(MAX_GUESTS, `Für mehr als ${MAX_GUESTS} Personen rufen Sie uns bitte an.`),

  name: z
    .string({ required_error: 'Bitte geben Sie Ihren Namen an.' })
    .trim()
    .min(2, 'Bitte geben Sie Ihren Namen an.')
    .max(80, 'Der Name ist zu lang.'),

  email: z
    .string({ required_error: 'Bitte geben Sie Ihre E-Mail-Adresse an.' })
    .trim()
    .min(1, 'Bitte geben Sie Ihre E-Mail-Adresse an.')
    .max(120, 'Die E-Mail-Adresse ist zu lang.')
    .email('Diese E-Mail-Adresse scheint nicht zu stimmen.'),

  telefon: z
    .string({ required_error: 'Bitte geben Sie eine Telefonnummer an.' })
    .trim()
    .min(6, 'Bitte geben Sie eine Telefonnummer an.')
    .max(32, 'Die Telefonnummer ist zu lang.')
    .regex(/^[0-9+\-()/ ]+$/, 'Bitte nur Ziffern, Leerzeichen und + - ( ).'),

  anlass: z.enum(OCCASIONS).optional(),

  nachricht: z.string().trim().max(600, 'Bitte höchstens 600 Zeichen.').optional(),

  datenschutz: z.literal(true, {
    errorMap: () => ({ message: 'Bitte bestätigen Sie die Datenschutzerklärung.' }),
  }),

  /**
   * Honeypot: für Menschen unsichtbar, Bots füllen ihn aus.
   * Alles außer leer gilt als Spam.
   */
  webseite: z.string().max(0).optional(),

  /** Optionales Turnstile-Token; nur geprüft, wenn ein Secret hinterlegt ist. */
  turnstileToken: z.string().optional(),
})

export type ReservationInput = z.infer<typeof reservationSchema>

/** Antwortformat der Pages-Function. */
export type ReservationResponse =
  | { ok: true; referenz: string; message: string }
  | { ok: false; message: string; fieldErrors?: Record<string, string[]> }
