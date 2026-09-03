import type { ButtonHTMLAttributes, ReactNode } from 'react'

type Variant = 'primary' | 'ghost'

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant
  children: ReactNode
}

const base =
  'group relative inline-flex items-center justify-center gap-3 px-7 py-4 text-[0.7rem] font-medium uppercase tracking-label transition-colors duration-500 ease-noir disabled:cursor-not-allowed disabled:opacity-50'

const variants: Record<Variant, string> = {
  // Messing-Kontur, die sich beim Hover mit einer Füllung von unten schließt.
  primary: 'border border-accent text-accent hover:text-bg',
  ghost: 'border border-transparent text-ink hover:text-accent',
}

export function Button({ variant = 'primary', className = '', children, ...rest }: ButtonProps) {
  return (
    <button {...rest} className={`${base} ${variants[variant]} ${className}`}>
      {variant === 'primary' ? (
        <span
          aria-hidden="true"
          className="absolute inset-0 origin-bottom scale-y-0 bg-accent transition-transform duration-[600ms] ease-noir group-hover:scale-y-100"
        />
      ) : null}
      <span className="relative z-10">{children}</span>
    </button>
  )
}
