import {
  formatGermanDate,
  reservationSchema,
  type ReservationInput,
  type ReservationResponse,
} from '../../src/lib/schema'

/**
 * POST /api/reserve — Cloudflare Pages Function.
 *
 * Validiert mit demselben Zod-Schema wie das Formular im Browser. Client-seitige
 * Prüfungen sind Komfort, diese hier ist die verbindliche.
 *
 * Es wird bewusst nur `onRequestPost` exportiert: Pages beantwortet alle
 * anderen Methoden dann von sich aus mit 405.
 */

type Env = {
  /** Optional. Ist er gesetzt, wird das Turnstile-Token geprüft. */
  TURNSTILE_SECRET?: string
  /** Optional, für den späteren E-Mail-Versand (siehe unten). */
  RESEND_API_KEY?: string
  /** Empfängeradresse des Hauses. */
  RESERVATION_INBOX?: string
}

const JSON_HEADERS = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
} as const

const json = (payload: ReservationResponse, status = 200): Response =>
  new Response(JSON.stringify(payload), { status, headers: JSON_HEADERS })

/** Kurze, gut vorlesbare Referenz, z. B. "NOIR-7K2QD". */
function referenceCode(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  const bytes = new Uint8Array(5)
  crypto.getRandomValues(bytes)
  let code = ''
  for (const byte of bytes) {
    code += alphabet[byte % alphabet.length]
  }
  return `NOIR-${code}`
}

/** Prüft das Turnstile-Token — nur wenn überhaupt ein Secret hinterlegt ist. */
async function turnstileOk(env: Env, token: string | undefined, ip: string | null): Promise<boolean> {
  if (!env.TURNSTILE_SECRET) return true
  if (!token) return false

  const body = new FormData()
  body.append('secret', env.TURNSTILE_SECRET)
  body.append('response', token)
  if (ip) body.append('remoteip', ip)

  try {
    const response = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
      method: 'POST',
      body,
    })
    const result = (await response.json()) as { success?: boolean }
    return result.success === true
  } catch {
    return false
  }
}

export const onRequestPost: PagesFunction<Env> = async (context) => {
  const { request, env } = context

  if (!request.headers.get('content-type')?.includes('application/json')) {
    return json({ ok: false, message: 'Es werden nur JSON-Anfragen angenommen.' }, 415)
  }

  let payload: unknown
  try {
    payload = await request.json()
  } catch {
    return json({ ok: false, message: 'Die Anfrage konnte nicht gelesen werden.' }, 400)
  }

  const parsed = reservationSchema.safeParse(payload)

  if (!parsed.success) {
    return json(
      {
        ok: false,
        message: 'Bitte prüfen Sie die markierten Felder.',
        fieldErrors: parsed.error.flatten().fieldErrors as Record<string, string[]>,
      },
      400,
    )
  }

  const data: ReservationInput = parsed.data

  // Honigtopf: Bots füllen das versteckte Feld. Wir antworten freundlich,
  // damit sie nicht lernen, woran sie gescheitert sind — legen aber nichts an.
  if (data.webseite && data.webseite.length > 0) {
    return json({
      ok: true,
      referenz: referenceCode(),
      message: 'Anfrage eingegangen.',
    })
  }

  const ip = request.headers.get('CF-Connecting-IP')
  if (!(await turnstileOk(env, data.turnstileToken, ip))) {
    return json(
      { ok: false, message: 'Die Spam-Prüfung ist fehlgeschlagen. Bitte laden Sie die Seite neu.' },
      403,
    )
  }

  const referenz = referenceCode()

  // Demo-Betrieb: die Anfrage landet im Function-Log, nicht in einem Postfach.
  console.log('[NOIR] Reservierungsanfrage', {
    referenz,
    datum: data.datum,
    datumLang: formatGermanDate(data.datum),
    uhrzeit: data.uhrzeit,
    personen: data.personen,
    name: data.name,
    email: data.email,
    telefon: data.telefon,
    anlass: data.anlass ?? 'keiner',
    nachricht: data.nachricht ?? '',
  })

  /*
   * ---------------------------------------------------------------------
   * Echter Versand — für den Produktivbetrieb einkommentieren.
   *
   * Voraussetzungen:
   *   1. Environment-Variablen in Cloudflare Pages setzen:
   *      RESEND_API_KEY      (Secret)
   *      RESERVATION_INBOX   (z. B. reservierung@noir-stuttgart.de)
   *   2. Absenderdomain in Resend verifizieren (SPF + DKIM).
   *
   * if (env.RESEND_API_KEY && env.RESERVATION_INBOX) {
   *   await fetch('https://api.resend.com/emails', {
   *     method: 'POST',
   *     headers: {
   *       Authorization: `Bearer ${env.RESEND_API_KEY}`,
   *       'Content-Type': 'application/json',
   *     },
   *     body: JSON.stringify({
   *       from: 'NOIR Reservierung <reservierung@noir-stuttgart.de>',
   *       to: [env.RESERVATION_INBOX],
   *       reply_to: data.email,
   *       subject: `Reservierung ${referenz} — ${formatGermanDate(data.datum)}, ${data.personen} Personen`,
   *       text: [
   *         `Referenz: ${referenz}`,
   *         `Datum: ${formatGermanDate(data.datum)} um ${data.uhrzeit} Uhr`,
   *         `Personen: ${data.personen}`,
   *         `Name: ${data.name}`,
   *         `E-Mail: ${data.email}`,
   *         `Telefon: ${data.telefon}`,
   *         `Anlass: ${data.anlass ?? 'keiner'}`,
   *         `Nachricht: ${data.nachricht ?? '—'}`,
   *       ].join('\n'),
   *     }),
   *   })
   * }
   *
   * Alternativ per SMTP: MailChannels oder ein eigener Relay-Worker.
   * ---------------------------------------------------------------------
   */

  return json({
    ok: true,
    referenz,
    message: `Vielen Dank, ${data.name}. Wir melden uns innerhalb von 24 Stunden.`,
  })
}
