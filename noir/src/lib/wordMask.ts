/** Klassenname des animierbaren Wort-Elements (siehe splitText.tsx). */
export const WORD_INNER_CLASS = 'split-word__inner'

/** Sammelt alle animierbaren Wort-Elemente innerhalb eines Containers. */
export function collectWords(root: HTMLElement | null): HTMLElement[] {
  if (!root) return []
  return Array.from(root.querySelectorAll<HTMLElement>(`.${WORD_INNER_CLASS}`))
}
