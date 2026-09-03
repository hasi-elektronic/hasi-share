/**
 * Geteilter Scroll-Fortschritt zwischen GSAP und den WebGL-Szenen.
 *
 * Bewusst ein veränderliches Modul-Objekt statt React-State: ScrollTrigger
 * schreibt hier bis zu 60-mal pro Sekunde hinein, `useFrame` liest daraus.
 * Über React-State würde jeder Scroll-Frame einen Re-Render auslösen.
 */
export type SceneProgress = {
  /** 0 = Hero in Ruhe, 1 = Hero vollständig weggescrollt. */
  hero: number
  /** Zeigerposition in Clip-Space (-1 … 1) für die Parallaxe. */
  pointerX: number
  pointerY: number
}

const progress: SceneProgress = { hero: 0, pointerX: 0, pointerY: 0 }

export function getSceneProgress(): SceneProgress {
  return progress
}

export function setHeroProgress(value: number): void {
  progress.hero = value
}

export function setPointer(x: number, y: number): void {
  progress.pointerX = x
  progress.pointerY = y
}
