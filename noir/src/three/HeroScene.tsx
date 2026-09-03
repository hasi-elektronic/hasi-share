import { Suspense, useRef } from 'react'
import { Canvas, useFrame } from '@react-three/fiber'
import { ContactShadows, Environment, Lightformer } from '@react-three/drei'
import * as THREE from 'three'
import { Plate } from './primitives/Plate'
import { Smoke } from './primitives/Smoke'
import { getSceneProgress } from '@/app/sceneProgress'

/**
 * Die Hero-Szene. Wird ausschließlich über React.lazy geladen, damit three.js
 * nicht im Erst-Bundle landet.
 */

function Stage() {
  const drift = useRef<THREE.Group>(null)
  const tilt = useRef<THREE.Group>(null)
  const spin = useRef<THREE.Group>(null)

  useFrame((_, rawDelta) => {
    // Delta begrenzen: nach einem Tab-Wechsel darf nichts springen.
    const delta = Math.min(rawDelta, 0.05)
    const progress = getSceneProgress()

    if (spin.current) {
      spin.current.rotation.y += delta * 0.12
    }

    if (tilt.current) {
      // Zeiger-Parallaxe, weich nachgezogen statt hart gesetzt.
      tilt.current.rotation.x = THREE.MathUtils.damp(
        tilt.current.rotation.x,
        -progress.pointerY * 0.14 + 0.06,
        3,
        delta,
      )
      tilt.current.rotation.z = THREE.MathUtils.damp(
        tilt.current.rotation.z,
        progress.pointerX * 0.07,
        3,
        delta,
      )
    }

    if (drift.current) {
      // Scroll-Fortschritt: der Teller sinkt weg und verkleinert sich.
      const target = progress.hero
      drift.current.position.y = THREE.MathUtils.damp(
        drift.current.position.y,
        -target * 1.9,
        6,
        delta,
      )
      const scale = 1 - target * 0.45
      drift.current.scale.setScalar(THREE.MathUtils.damp(drift.current.scale.x, scale, 6, delta))
    }
  })

  return (
    <group ref={drift} position={[0, -0.35, 0]}>
      <group ref={tilt}>
        <group ref={spin}>
          <Plate />
        </group>
        <Smoke />
        {/* Weicher Kontaktschatten, einmal gebacken statt jeden Frame. */}
        <ContactShadows
          position={[0, -0.03, 0]}
          opacity={0.55}
          scale={5}
          blur={3.2}
          far={1.4}
          resolution={256}
          color="#000000"
          frames={1}
        />
      </group>
    </group>
  )
}

function Lighting() {
  return (
    <>
      <ambientLight intensity={0.18} />
      {/* Warmes Kerzenlicht von vorn rechts. */}
      <spotLight
        position={[2.6, 3.4, 2.2]}
        angle={0.55}
        penumbra={1}
        intensity={38}
        color="#ffd8a3"
      />
      {/* Messingfarbene Kante von hinten links. */}
      <pointLight position={[-2.4, 1.1, -2.2]} intensity={9} color="#c8a96a" />

      {/*
        Prozedurale Umgebung aus Lightformern statt HDR-Datei: keine externen
        Assets, einmal gebacken (frames={1}), reicht für die Messing-Reflexe.
      */}
      <Environment resolution={128} frames={1}>
        <Lightformer intensity={2.2} position={[0, 3, 1]} scale={[6, 3, 1]} color="#fff1d8" />
        <Lightformer intensity={0.8} position={[-3, 1, -2]} scale={[4, 4, 1]} color="#c8a96a" />
        <Lightformer intensity={0.35} position={[3, -1, 2]} scale={[4, 2, 1]} color="#5a1f2b" />
      </Environment>
    </>
  )
}

type HeroSceneProps = {
  /** false pausiert den Frame-Loop vollständig (Tab versteckt, außer Sicht). */
  active: boolean
}

export default function HeroScene({ active }: HeroSceneProps) {
  return (
    <Canvas
      frameloop={active ? 'always' : 'never'}
      dpr={[1, 1.5]}
      gl={{ antialias: true, powerPreference: 'high-performance', alpha: true }}
      camera={{ position: [0, 0.75, 3.9], fov: 34 }}
      // Der Canvas ist reine Dekoration — der Text darüber trägt die Bedeutung.
      aria-hidden="true"
      style={{ pointerEvents: 'none' }}
    >
      <Suspense fallback={null}>
        <Lighting />
        <Stage />
      </Suspense>
    </Canvas>
  )
}
