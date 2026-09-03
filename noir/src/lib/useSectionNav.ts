import { useCallback } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { scrollToId } from '@/app/lenis'

export type SectionLink = { id: string; label: string }

export const SECTION_LINKS: SectionLink[] = [
  { id: 'manifest', label: 'Haltung' },
  { id: 'menue', label: 'Menü' },
  { id: 'chef', label: 'Küchenchef' },
  { id: 'galerie', label: 'Galerie' },
  { id: 'reservierung', label: 'Reservierung' },
]

/**
 * Springt zu einer Sektion. Von den Rechtsseiten aus wird zuerst zur
 * Startseite navigiert und das Ziel im Router-State mitgegeben.
 */
export function useSectionNav(): (id: string) => void {
  const navigate = useNavigate()
  const { pathname } = useLocation()

  return useCallback(
    (id: string) => {
      if (pathname === '/') {
        scrollToId(id)
      } else {
        navigate('/', { state: { scrollTo: id } })
      }
    },
    [navigate, pathname],
  )
}
