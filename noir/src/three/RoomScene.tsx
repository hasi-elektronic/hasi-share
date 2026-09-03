import { Suspense, useMemo, useRef, useState } from 'react'
import { Canvas, useFrame } from '@react-three/fiber'
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

const ROOM = { width: 9, height: 3.4, depth: 9 }

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

      {/* Fensterfront zur Königstraße */}
      <mesh material={materials.window} position={[0, 1.5, ROOM.depth / 2 - 0.02]}>
        <planeGeometry args={[5.4, 1.9]} />
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

/** Dreht die Szene langsam, bis der Gast selbst zugreift. */
function AutoRotate({ enabled }: { enabled: boolean }) {
  const group = useRef<THREE.Group>(null)
  useFrame((state, delta) => {
    if (!enabled) return
    // Kamera um den Mittelpunkt führen statt die Geometrie zu drehen.
    const radius = Math.hypot(state.camera.position.x, state.camera.position.z)
    const angle = Math.atan2(state.camera.position.z, state.camera.position.x) + delta * 0.06
    state.camera.position.x = Math.cos(angle) * radius
    state.camera.position.z = Math.sin(angle) * radius
    state.camera.lookAt(0, 1, 0)
  })
  return <group ref={group} />
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
      camera={{ position: [5.4, 2.4, 5.4], fov: 42 }}
      onPointerDown={() => setUserTouched(true)}
      onWheel={() => setUserTouched(true)}
    >
      <color attach="background" args={['#0a0a0b']} />
      {/* Nebel verschluckt die Ecken — der Raum wirkt größer, als er ist. */}
      <fog attach="fog" args={['#0a0a0b', 6, 20]} />

      <ambientLight intensity={0.14} />
      <hemisphereLight args={['#3a2f22', '#08080a', 0.35]} />

      <Suspense fallback={null}>
        <Room />

        {HOTSPOTS.map((hotspot) => (
          <Html
            key={hotspot.id}
            position={hotspot.position}
            center
            distanceFactor={9}
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

        <AutoRotate enabled={rotating} />

        <OrbitControls
          target={[0, 1, 0]}
          enablePan={false}
          enableDamping
          dampingFactor={0.08}
          minDistance={3.5}
          maxDistance={11}
          // Nie unter den Boden und nie senkrecht von oben.
          minPolarAngle={Math.PI * 0.18}
          maxPolarAngle={Math.PI * 0.49}
        />
      </Suspense>
    </Canvas>
  )
}
