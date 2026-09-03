import type { Config } from 'tailwindcss'

export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        bg: 'rgb(var(--bg-rgb) / <alpha-value>)',
        elevated: 'rgb(var(--bg-elevated-rgb) / <alpha-value>)',
        ink: 'rgb(var(--ink-rgb) / <alpha-value>)',
        muted: 'rgb(var(--ink-muted-rgb) / <alpha-value>)',
        accent: 'rgb(var(--accent-rgb) / <alpha-value>)',
        'accent-deep': 'rgb(var(--accent-deep-rgb) / <alpha-value>)',
        wine: 'rgb(var(--wine-rgb) / <alpha-value>)',
        hairline: 'rgb(var(--ink-rgb) / 0.12)',
      },
      fontFamily: {
        display: ['"Cormorant Garamond"', 'Georgia', 'serif'],
        sans: ['Inter', 'system-ui', '-apple-system', 'Segoe UI', 'sans-serif'],
      },
      letterSpacing: {
        label: '0.2em',
      },
      maxWidth: {
        shell: '1440px',
      },
      spacing: {
        section: 'clamp(6rem, 12vh, 12rem)',
        gutter: 'clamp(1.25rem, 5vw, 4.5rem)',
      },
      transitionTimingFunction: {
        noir: 'cubic-bezier(0.16, 1, 0.3, 1)',
      },
      screens: {
        xs: '400px',
      },
    },
  },
  plugins: [],
} satisfies Config
