import { useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { Link } from 'react-router-dom'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'

import { FieldShell, SelectField, TextField, TextareaField } from '@/components/Field'
import { EASE_NOIR } from '@/lib/motion'
import {
  MAX_GUESTS,
  MIN_GUESTS,
  OCCASIONS,
  OCCASION_LABELS,
  RESERVATION_TIMES,
  formatGermanDate,
  isClosedDay,
  reservationSchema,
  todayInBerlin,
  type ReservationInput,
  type ReservationResponse,
} from '@/lib/schema'

type Status = 'idle' | 'sending' | 'success' | 'error'

type Confirmation = {
  referenz: string
  daten: ReservationInput
}

export function Reservation() {
  const [status, setStatus] = useState<Status>('idle')
  const [serverMessage, setServerMessage] = useState('')
  const [confirmation, setConfirmation] = useState<Confirmation | null>(null)
  const [shakeKey, setShakeKey] = useState(0)

  const {
    register,
    handleSubmit,
    watch,
    setValue,
    formState: { errors },
  } = useForm<ReservationInput>({
    resolver: zodResolver(reservationSchema),
    mode: 'onBlur',
    defaultValues: {
      datum: '',
      uhrzeit: '19:00',
      personen: 2,
      name: '',
      email: '',
      telefon: '',
      anlass: 'keiner',
      nachricht: '',
      datenschutz: false,
      webseite: '',
    },
  })

  const personen = watch('personen')
  const datum = watch('datum')
  const ruhetag = Boolean(datum) && isClosedDay(datum)

  const onSubmit = async (values: ReservationInput) => {
    setStatus('sending')
    setServerMessage('')

    try {
      const response = await fetch('/api/reserve', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(values),
      })
      const payload = (await response.json()) as ReservationResponse

      if (!response.ok || !payload.ok) {
        setStatus('error')
        setShakeKey((key) => key + 1)
        setServerMessage(
          payload.ok
            ? 'Die Anfrage konnte nicht verarbeitet werden.'
            : payload.message ||
                'Die Anfrage konnte nicht verarbeitet werden. Bitte rufen Sie uns an.',
        )
        return
      }

      // Eingaben bleiben stehen — die Bestätigung zeigt sie noch einmal.
      setConfirmation({ referenz: payload.referenz, daten: values })
      setStatus('success')
    } catch {
      setStatus('error')
      setShakeKey((key) => key + 1)
      setServerMessage(
        'Keine Verbindung zum Server. Bitte versuchen Sie es erneut oder rufen Sie uns an: +49 711 9028440.',
      )
    }
  }

  const stepGuests = (delta: number) => {
    const next = Math.min(MAX_GUESTS, Math.max(MIN_GUESTS, (personen ?? MIN_GUESTS) + delta))
    setValue('personen', next, { shouldValidate: true })
  }

  return (
    <section id="reservierung" aria-labelledby="reservierung-titel" className="section-y">
      <div className="mx-auto w-full max-w-shell px-gutter">
        <div className="grid gap-12 lg:grid-cols-12 lg:gap-16">
          {/* --- Begleittext ------------------------------------------------ */}
          <div className="lg:col-span-4">
            <p className="label label-accent">Reservierung</p>
            <h2 id="reservierung-titel" className="display mt-6 text-[clamp(2.5rem,6vw,4.5rem)]">
              Ein Tisch,
              <br />
              ein Abend.
            </h2>
            <p className="mt-8 max-w-[38ch] text-pretty leading-relaxed text-muted">
              Wir haben zwölf Plätze. Der Service beginnt für alle Gäste um 19 Uhr — wer später
              kommt, verpasst den ersten Gang. Ihre Anfrage bestätigen wir persönlich innerhalb von
              24 Stunden.
            </p>

            <dl className="mt-12 space-y-5 border-t border-hairline pt-8 text-sm">
              <div className="flex justify-between gap-6">
                <dt className="label">Ruhetag</dt>
                <dd className="text-ink">Montag</dd>
              </div>
              <div className="flex justify-between gap-6">
                <dt className="label">Telefon</dt>
                <dd>
                  <a href="tel:+497119028440" className="link-underline text-ink">
                    +49 711 9028440
                  </a>
                </dd>
              </div>
              <div className="flex justify-between gap-6">
                <dt className="label">Größere Runden</dt>
                <dd className="text-right text-muted">Ab neun Personen bitte telefonisch</dd>
              </div>
            </dl>
          </div>

          {/* --- Formular / Bestätigung ------------------------------------- */}
          <div className="lg:col-span-7 lg:col-start-6">
            <AnimatePresence mode="wait">
              {status === 'success' && confirmation ? (
                <ConfirmationCard key="bestaetigung" confirmation={confirmation} />
              ) : (
                <motion.form
                  key={`formular-${shakeKey}`}
                  noValidate
                  onSubmit={handleSubmit(onSubmit)}
                  initial={shakeKey === 0 ? false : { x: 0 }}
                  animate={
                    shakeKey === 0 ? undefined : { x: [0, -9, 8, -5, 3, 0] }
                  }
                  transition={{ duration: 0.5, ease: 'easeOut' }}
                  className="grid gap-x-8 gap-y-9 sm:grid-cols-2"
                >
                  <FieldShell
                    id="datum"
                    label="Datum"
                    error={errors.datum?.message}
                    hint={ruhetag ? undefined : 'Montags ist Ruhetag.'}
                  >
                    <TextField
                      id="datum"
                      type="date"
                      min={todayInBerlin()}
                      aria-invalid={Boolean(errors.datum)}
                      aria-describedby={errors.datum ? 'datum-fehler' : undefined}
                      {...register('datum')}
                    />
                  </FieldShell>

                  <FieldShell id="uhrzeit" label="Uhrzeit" error={errors.uhrzeit?.message}>
                    <SelectField
                      id="uhrzeit"
                      aria-invalid={Boolean(errors.uhrzeit)}
                      {...register('uhrzeit')}
                    >
                      {RESERVATION_TIMES.map((time) => (
                        <option key={time} value={time} className="bg-elevated">
                          {time} Uhr
                        </option>
                      ))}
                    </SelectField>
                  </FieldShell>

                  {/* Personen: Schrittzähler statt Zahlenfeld */}
                  <FieldShell
                    id="personen"
                    label="Personen"
                    error={errors.personen?.message}
                    className="sm:col-span-2"
                  >
                    <div className="flex items-center gap-6 border-b border-hairline pb-3">
                      <StepperButton
                        label="Eine Person weniger"
                        symbol="−"
                        onClick={() => stepGuests(-1)}
                        disabled={(personen ?? MIN_GUESTS) <= MIN_GUESTS}
                      />
                      <output
                        htmlFor="personen"
                        className="font-display text-3xl tabular-nums text-ink"
                      >
                        {personen ?? MIN_GUESTS}
                      </output>
                      <StepperButton
                        label="Eine Person mehr"
                        symbol="+"
                        onClick={() => stepGuests(1)}
                        disabled={(personen ?? MIN_GUESTS) >= MAX_GUESTS}
                      />
                      <span className="label ml-auto">
                        {MIN_GUESTS}–{MAX_GUESTS} Personen
                      </span>
                      <input
                        id="personen"
                        type="hidden"
                        {...register('personen', { valueAsNumber: true })}
                      />
                    </div>
                  </FieldShell>

                  <FieldShell id="name" label="Name" error={errors.name?.message}>
                    <TextField
                      id="name"
                      autoComplete="name"
                      placeholder="Vor- und Nachname"
                      aria-invalid={Boolean(errors.name)}
                      {...register('name')}
                    />
                  </FieldShell>

                  <FieldShell id="telefon" label="Telefon" error={errors.telefon?.message}>
                    <TextField
                      id="telefon"
                      type="tel"
                      autoComplete="tel"
                      placeholder="+49 …"
                      aria-invalid={Boolean(errors.telefon)}
                      {...register('telefon')}
                    />
                  </FieldShell>

                  <FieldShell
                    id="email"
                    label="E-Mail"
                    error={errors.email?.message}
                    className="sm:col-span-2"
                  >
                    <TextField
                      id="email"
                      type="email"
                      autoComplete="email"
                      placeholder="name@beispiel.de"
                      aria-invalid={Boolean(errors.email)}
                      {...register('email')}
                    />
                  </FieldShell>

                  <FieldShell id="anlass" label="Anlass (optional)" error={errors.anlass?.message}>
                    <SelectField id="anlass" {...register('anlass')}>
                      {OCCASIONS.map((value) => (
                        <option key={value} value={value} className="bg-elevated">
                          {OCCASION_LABELS[value]}
                        </option>
                      ))}
                    </SelectField>
                  </FieldShell>

                  <FieldShell
                    id="nachricht"
                    label="Nachricht (optional)"
                    error={errors.nachricht?.message}
                    hint="Allergien, Unverträglichkeiten, Wünsche."
                  >
                    <TextareaField id="nachricht" {...register('nachricht')} />
                  </FieldShell>

                  {/* Honigtopf: für Menschen unsichtbar, für Bots verlockend. */}
                  <div aria-hidden="true" className="absolute -left-[9999px] h-0 w-0 overflow-hidden">
                    <label htmlFor="webseite">Webseite nicht ausfüllen</label>
                    <input id="webseite" type="text" tabIndex={-1} autoComplete="off" {...register('webseite')} />
                  </div>

                  <div className="sm:col-span-2">
                    <label className="flex items-start gap-4 text-sm text-muted">
                      <input
                        type="checkbox"
                        aria-invalid={Boolean(errors.datenschutz)}
                        className="mt-1 h-4 w-4 shrink-0 accent-[color:var(--accent)]"
                        {...register('datenschutz')}
                      />
                      <span>
                        Ich habe die{' '}
                        <Link to="/datenschutz" className="link-underline text-ink">
                          Datenschutzerklärung
                        </Link>{' '}
                        gelesen und bin damit einverstanden, dass meine Angaben zur Bearbeitung
                        dieser Anfrage gespeichert werden.
                      </span>
                    </label>
                    {errors.datenschutz ? (
                      <p role="alert" className="mt-2 text-xs text-accent">
                        {errors.datenschutz.message}
                      </p>
                    ) : null}
                  </div>

                  <div className="flex flex-wrap items-center gap-6 sm:col-span-2">
                    <button
                      type="submit"
                      disabled={status === 'sending'}
                      data-cursor="Absenden"
                      className="group relative inline-flex items-center justify-center overflow-hidden border border-accent px-9 py-4 text-[0.7rem] uppercase tracking-label text-accent transition-colors duration-500 ease-noir hover:text-bg disabled:cursor-not-allowed disabled:opacity-50"
                    >
                      <span
                        aria-hidden="true"
                        className="absolute inset-0 origin-bottom scale-y-0 bg-accent transition-transform duration-[600ms] ease-noir group-hover:scale-y-100"
                      />
                      <span className="relative z-10">
                        {status === 'sending' ? 'Wird gesendet …' : 'Anfrage senden'}
                      </span>
                    </button>

                    {status === 'error' && serverMessage ? (
                      <p role="alert" className="max-w-[42ch] text-sm text-accent">
                        {serverMessage}
                      </p>
                    ) : null}
                  </div>
                </motion.form>
              )}
            </AnimatePresence>
          </div>
        </div>
      </div>
    </section>
  )
}

/* ------------------------------------------------------------------ Teile */

function StepperButton({
  label,
  symbol,
  onClick,
  disabled,
}: {
  label: string
  symbol: string
  onClick: () => void
  disabled: boolean
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-label={label}
      className="flex h-10 w-10 items-center justify-center border border-hairline text-lg text-ink transition-colors duration-500 ease-noir hover:border-accent hover:text-accent disabled:cursor-not-allowed disabled:opacity-30"
    >
      {symbol}
    </button>
  )
}

function ConfirmationCard({ confirmation }: { confirmation: Confirmation }) {
  const { daten, referenz } = confirmation

  return (
    <motion.div
      initial={{ opacity: 0, y: 24 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0 }}
      transition={{ duration: 0.7, ease: EASE_NOIR }}
      className="border border-hairline p-8 sm:p-12"
      aria-live="polite"
    >
      {/* Messinglinie zeichnet sich einmal quer durch die Karte. */}
      <motion.span
        aria-hidden="true"
        initial={{ scaleX: 0 }}
        animate={{ scaleX: 1 }}
        transition={{ duration: 1.2, ease: EASE_NOIR, delay: 0.2 }}
        className="block h-px w-full origin-left bg-accent"
      />

      <p className="label label-accent mt-8">Anfrage eingegangen</p>
      <h3 className="display mt-5 text-[clamp(1.75rem,4vw,3rem)]">
        Wir haben Ihren Tisch notiert.
      </h3>
      <p className="mt-5 max-w-[46ch] text-sm leading-relaxed text-muted">
        Sie erhalten die verbindliche Bestätigung innerhalb von 24 Stunden per E-Mail an{' '}
        <span className="text-ink">{daten.email}</span>. Ihre Referenz lautet{' '}
        <span className="text-accent">{referenz}</span>.
      </p>

      <dl className="mt-10 grid gap-x-8 gap-y-5 border-t border-hairline pt-8 sm:grid-cols-2">
        <Summary label="Datum" value={formatGermanDate(daten.datum)} />
        <Summary label="Uhrzeit" value={`${daten.uhrzeit} Uhr`} />
        <Summary label="Personen" value={String(daten.personen)} />
        <Summary label="Name" value={daten.name} />
        <Summary label="Telefon" value={daten.telefon} />
        {daten.anlass && daten.anlass !== 'keiner' ? (
          <Summary label="Anlass" value={OCCASION_LABELS[daten.anlass]} />
        ) : null}
        {daten.nachricht ? (
          <div className="sm:col-span-2">
            <Summary label="Nachricht" value={daten.nachricht} />
          </div>
        ) : null}
      </dl>

      <p className="mt-10 text-xs text-muted">
        Demo-Hinweis: Diese Seite ist eine Schaustelle. Es wurde keine echte Reservierung angelegt
        und keine E-Mail versendet.
      </p>
    </motion.div>
  )
}

function Summary({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="label">{label}</dt>
      <dd className="mt-2 text-ink">{value}</dd>
    </div>
  )
}
