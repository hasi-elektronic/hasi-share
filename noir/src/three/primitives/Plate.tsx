import { useEffect, useMemo } from 'react'
import * as THREE from 'three'

/**
 * Schwarzer Keramikteller mit einem schwebenden Messingring.
 *
 * Alles prozedural: ein Lathe-Profil für den Teller, ein Torus für den Ring.
 * Kein GLTF, kein Download — zusammen unter 6.000 Dreiecken.
 */

// Radius/Höhe-Paare: erst die Oberseite nach außen, dann die Unterseite zurück.
const PROFILE: [number, number][] = [
  [0.0, 0.0],
  [0.42, 0.012],
  [0.72, 0.05],
  [0.92, 0.115],
  [1.02, 0.162],
  [1.06, 0.175],
  [1.06, 0.158],
  [1.0, 0.132],
  [0.86, 0.076],
  [0.6, 0.024],
  [0.3, 0.004],
  [0.0, -0.016],
]

export function Plate() {
  const plateGeometry = useMemo(() => {
    const points = PROFILE.map(([x, y]) => new THREE.Vector2(x, y))
    return new THREE.LatheGeometry(points, 96)
  }, [])

  const ringGeometry = useMemo(() => new THREE.TorusGeometry(0.66, 0.011, 14, 128), [])

  const plateMaterial = useMemo(
    () =>
      new THREE.MeshPhysicalMaterial({
        color: new THREE.Color('#0e0e11'),
        roughness: 0.44,
        metalness: 0.0,
        clearcoat: 0.65,
        clearcoatRoughness: 0.32,
        side: THREE.DoubleSide,
      }),
    [],
  )

  const brassMaterial = useMemo(
    () =>
      new THREE.MeshStandardMaterial({
        color: new THREE.Color('#c8a96a'),
        metalness: 1,
        roughness: 0.22,
      }),
    [],
  )

  useEffect(() => {
    return () => {
      plateGeometry.dispose()
      ringGeometry.dispose()
      plateMaterial.dispose()
      brassMaterial.dispose()
    }
  }, [plateGeometry, ringGeometry, plateMaterial, brassMaterial])

  return (
    <group>
      <mesh geometry={plateGeometry} material={plateMaterial} />
      {/* Der Ring liegt flach und schwebt eine Handbreit über dem Rand. */}
      <mesh
        geometry={ringGeometry}
        material={brassMaterial}
        rotation={[-Math.PI / 2, 0, 0]}
        position={[0, 0.3, 0]}
      />
    </group>
  )
}
