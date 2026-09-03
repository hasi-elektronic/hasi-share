type WordmarkProps = {
  className?: string
  /** Untertitel unter dem Schriftzug, z. B. im Footer. */
  withSub?: boolean
}

/** Der Schriftzug — überall dieselbe Laufweite, damit er wiedererkennbar bleibt. */
export function Wordmark({ className = '', withSub = false }: WordmarkProps) {
  return (
    <span className={`inline-flex flex-col leading-none ${className}`}>
      <span className="font-display text-[1.35rem] font-normal tracking-[0.42em] text-ink">
        NOIR
      </span>
      {withSub ? (
        <span className="label mt-2 text-[0.6rem] tracking-[0.3em]">Fine Dining · Stuttgart</span>
      ) : null}
    </span>
  )
}
