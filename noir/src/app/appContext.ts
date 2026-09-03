import { createContext, useContext } from 'react'

export type AppEnv = {
  /** System fordert reduzierte Bewegung an. */
  reducedMotion: boolean
  /** Touch-Gerät oder anderer grober Zeiger. */
  coarsePointer: boolean
  /** Hardware-Urteil: darf überhaupt eine WebGL-Szene gemountet werden? */
  allow3D: boolean
}

export const defaultAppEnv: AppEnv = {
  reducedMotion: false,
  coarsePointer: false,
  allow3D: false,
}

export const AppContext = createContext<AppEnv>(defaultAppEnv)

export function useAppEnv(): AppEnv {
  return useContext(AppContext)
}
