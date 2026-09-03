import type { InputHTMLAttributes, ReactNode, SelectHTMLAttributes, TextareaHTMLAttributes } from 'react'
import { forwardRef } from 'react'

type FieldShellProps = {
  id: string
  label: string
  error?: string | undefined
  hint?: string | undefined
  children: ReactNode
  className?: string
}

/** Label, Feld, Hinweis und Fehlermeldung — einmal definiert, überall gleich. */
export function FieldShell({ id, label, error, hint, children, className = '' }: FieldShellProps) {
  return (
    <div className={className}>
      <label htmlFor={id} className="label block">
        {label}
      </label>
      <div className="mt-3">{children}</div>
      {hint && !error ? <p className="mt-2 text-xs text-muted">{hint}</p> : null}
      {error ? (
        <p id={`${id}-fehler`} role="alert" className="mt-2 text-xs text-accent">
          {error}
        </p>
      ) : null}
    </div>
  )
}

const control =
  'w-full border-0 border-b border-hairline bg-transparent px-0 py-3 text-ink outline-none transition-colors duration-500 ease-noir placeholder:text-muted/60 focus:border-accent focus-visible:outline-none aria-[invalid=true]:border-accent'

export const TextField = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(
  function TextField(props, ref) {
    return <input ref={ref} {...props} className={`${control} ${props.className ?? ''}`} />
  },
)

export const SelectField = forwardRef<HTMLSelectElement, SelectHTMLAttributes<HTMLSelectElement>>(
  function SelectField({ children, ...props }, ref) {
    return (
      <select ref={ref} {...props} className={`${control} appearance-none ${props.className ?? ''}`}>
        {children}
      </select>
    )
  },
)

export const TextareaField = forwardRef<
  HTMLTextAreaElement,
  TextareaHTMLAttributes<HTMLTextAreaElement>
>(function TextareaField(props, ref) {
  return (
    <textarea ref={ref} rows={3} {...props} className={`${control} resize-none ${props.className ?? ''}`} />
  )
})
