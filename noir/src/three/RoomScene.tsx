import { Suspense, useMemo, useState } from 'react'
import { Canvas } from '@react-three/fiber'
import { Html, OrbitControls } from '@react-three/drei'
import * as THREE from 'three'
import { HOTSPOTS } from '@/data/room'

/**
 * "Der Raum" — ein stilisierter Gastraum, vollständig aus Grundkörpern.
 *
 * Budget: Boden, ein umgestülpter Raumkubus, fünf Tische mit Stühlen, fünf
 * Pendelleuchten. Zusammen unter 5.000 Dreiecken, keine Texturen, keine
 * externen Dateien.
 */

const TABLES: [number, number][] = [
  [-2.6, -1.6],
  [-1.0, 1.4],
  [1.2, -0.4],
  [2.8, -2.4],
  [0.4, 2.8],
]

const ROOM = { width: 10, height: 3.4, depth: 10 }

function Room() {
  const materials = useMemo(() => {
    return {
      shell: new THREE.MeshStandardMaterial({
        color: new THREE.Color('#141416'),
        roughness: 0.95,
        metalness: 0,
        side: THREE.BackSide,
      }),
      floor: new THREE.MeshStandardMaterial({
        color: new THREE.Color('#0d0d0f'),
        roughness: 0.6,
        metalness: 0.15,
      }),
      linen: new THREE.MeshStandardMaterial({
        color: new THREE.Color('#1c1b19'),
        roughness: 0.85,
      }),
      brass: new THREE.MeshStandardMaterial({
        color: new THREE.Color('#c8a96a'),
        metalness: 1,
        roughness: 0.3,
      }),
      glow: new THREE.MeshBasicMaterial({ color: new THREE.Color('#ffd9a3') }),
      window: new THREE.MeshBasicMaterial({ color: new THREE.Color('#2b3448') }),
    }
  }, [])

  return (
    <group>
      {/* Raumhülle: ein einziger, nach innen gedrehter Kubus. */}
      <mesh material={materials.shell} position={[0, ROOM.height / 2 - 0.01, 0]}>
        <boxGeometry args={[ROOM.width, ROOM.height, ROOM.depth]} />
      </mesh>

      <mesh material={materials.floor} rotation={[-Math.PI / 2, 0, 0]}>
        <planeGeometry args={[ROOM.width, ROOM.depth]} />
      </mesh>

      {/* Fensterfront zur Königstraße — nach innen gedreht, damit sie nur
          von innerhalb des Raums zu sehen ist. */}
      <mesh
        material={materials.window}
        position={[0, 1.55, ROOM.depth / 2 - 0.04]}
        rotation={[0, Math.PI, 0]}
      >
        <planeGeometry args={[5.6, 1.9]} />
      </mesh>

      {/* Küchenzeile an der Rückwand */}
      <mesh material={materials.linen} position={[-2.7, 0.45, -3.6]}>
        <boxGeometry args={[3.2, 0.9, 0.7]} />
      </mesh>
      <mesh material={materials.brass} position={[-2.7, 0.92, -3.6]}>
        <boxGeometry args={[3.24, 0.04, 0.74]} />
      </mesh>

      {TABLES.map(([x, z], index) => (
        <Table key={`${x}-${z}`} x={x} z={z} materials={materials} index={index} />
      ))}
    </group>
  )
}

type Materials = {
  linen: THREE.Material
  brass: THREE.Material
  glow: THREE.Material
}

function Table({
  x,
  z,
  materials,
  index,
}: {
  x: number
  z: number
  materials: Materials
  index: number
}) {
  return (
    <group position={[x, 0, z]}>
      {/* Platte + Säule */}
      <mesh material={materials.linen} position={[0, 0.74, 0]}>
        <cylinderGeometry args={[0.55, 0.55, 0.05, 24]} />
      </mesh>
      <mesh material={materials.linen} position={[0, 0.36, 0]}>
        <cylinderGeometry args={[0.07, 0.12, 0.72, 12]} />
      </mesh>

      {/* Zwei Stühle, leicht versetzt */}
      <mesh material={materials.linen} position={[0, 0.42, 0.85]} rotation={[0, 0.2, 0]}>
        <boxGeometry args={[0.42, 0.84, 0.42]} />
      </mesh>
      <mesh material={materials.linen} position={[0, 0.42, -0.85]} rotation={[0, -0.15, 0]}>
        <boxGeometry args={[0.42, 0.84, 0.42]} />
      </mesh>

      {/* Kerze auf dem Tisch */}
      <mesh material={materials.glow} position={[0, 0.82, 0]}>
        <sphereGeometry args={[0.035, 8, 6]} />
      </mesh>
      <pointLight position={[0, 0.95, 0]} intensity={0.9} distance={2.6} color="#ffb763" />

      {/* Pendelleuchte darüber */}
      <mesh material={materials.brass} position={[0, 2.1, 0]}>
        <cylinderGeometry args={[0.16, 0.2, 0.16, 16, 1, true]} />
      </mesh>
      <mesh material={materials.glow} position={[0, 2.02, 0]}>
        <sphereGeometry args={[0.07, 10, 8]} />
      </mesh>
      <pointLight
        position={[0, 1.95, 0]}
        intensity={index === 0 ? 5 : 3.4}
        distance={4.2}
        color="#ffd9a3"
      />
    </group>
  )
}

type RoomSceneProps = {
  active: boolean
  autoRotate: boolean
  selectedId: string | null
  onSelect: (id: string) => void
}

export default function RoomScene({ active, autoRotate, selectedId, onSelect }: RoomSceneProps) {
  const [userTouched, setUserTouched] = useState(false)
  const rotating = autoRotate && !userTouched

  return (
    <Canvas
      frameloop={active ? 'always' : 'never'}
      dpr={[1, 1.5]}
      gl={{ antialias: true, powerPreference: 'high-performance' }}
      // Die Kamera bleibt innerhalb der Raumhülle — von außen wären die
      // Wände (BackSide) unsichtbar und man sähe in eine leere Schachtel.
      camera={{ position: [2.8, 2.2, 3.2], fov: 46 }}
      // Sobald der Zeiger die Szene erreicht, steht sie still: bewegliche
      // Hotspots lassen sich sonst nur schwer treffen.
      onPointerEnter={() => setUserTouched(true)}
      onPointerDown={() => setUserTouched(true)}
      onWheel={() => setUserTouched(true)}
    >
      <color attach="background" args={['#0a0a0b']} />
      {/* Nebel verschluckt die Ecken — der Raum wirkt größer, als er ist. */}
      <fog attach="fog" args={['#0a0a0b', 3.5, 13]} />

      <ambientLight intensity={0.14} />
      <hemisphereLight args={['#3a2f22', '#08080a', 0.35]} />

      <Suspense fallback={null}>
        <Room />

        {HOTSPOTS.map((hotspot) => (
          <Html
            key={hotspot.id}
            position={hotspot.position}
            center
            // Bewusst ohne distanceFactor: die Beschriftung soll immer gleich
            // groß bleiben. Sonst wächst ein naher Punkt über das halbe Bild.
            zIndexRange={[20, 0]}
          >
            <button
              type="button"
              onClick={() => onSelect(hotspot.id)}
              aria-label={`${hotspot.titel} — Details anzeigen`}
              className={`hotspot ${selectedId === hotspot.id ? 'hotspot--active' : ''}`}
            >
              <span className="hotspot__ring" aria-hidden="true" />
              <span className="hotspot__label">{hotspot.titel}</span>
            </button>
          </Html>
        ))}

        <OrbitControls
          target={[0, 0.9, 0]}
          enablePan={false}
          enableDamping
          dampingFactor={0.08}
          // Die eingebaute Drehung statt einer eigenen Schleife: sie rechnet
          // mit derselben Kugelkoordinate wie die Dämpfung und gerät dadurch
          // nicht mit der Benutzereingabe in Streit.
          autoRotate={rotating}
          autoRotateSpeed={0.35}
          minDistance={2.4}
          maxDistance={4.8}
          // Nie unter den Boden und nie senkrecht von oben.
          minPolarAngle={Math.PI * 0.18}
          maxPolarAngle={Math.PI * 0.49}
        />
      </Suspense>
    </Canvas>
  )
}
