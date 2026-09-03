import { useEffect, useMemo } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import { smokeFragmentShader, smokeVertexShader } from '../shaders/smoke'

type SmokeProps = {
  count?: number
  /** Höhe, über die ein Wisp aufsteigt. */
  spread?: number
  opacity?: number
}

export function Smoke({ count = 260, spread = 2.6, opacity = 0.5 }: SmokeProps) {
  const dpr = useThree((state) => state.viewport.dpr)

  const geometry = useMemo(() => {
    const positions = new Float32Array(count * 3)
    const seeds = new Float32Array(count)
    const scales = new Float32Array(count)
    const speeds = new Float32Array(count)

    for (let i = 0; i < count; i += 1) {
      // Startpunkte in einer flachen Scheibe knapp über dem Teller.
      const radius = Math.sqrt(Math.random()) * 0.42
      const angle = Math.random() * Math.PI * 2
      positions[i * 3] = Math.cos(angle) * radius
      positions[i * 3 + 1] = -0.05 + Math.random() * 0.1
      positions[i * 3 + 2] = Math.sin(angle) * radius

      seeds[i] = Math.random()
      scales[i] = 0.5 + Math.random() * 1.6
      speeds[i] = 0.6 + Math.random() * 0.9
    }

    const geo = new THREE.BufferGeometry()
    geo.setAttribute('position', new THREE.BufferAttribute(positions, 3))
    geo.setAttribute('aSeed', new THREE.BufferAttribute(seeds, 1))
    geo.setAttribute('aScale', new THREE.BufferAttribute(scales, 1))
    geo.setAttribute('aSpeed', new THREE.BufferAttribute(speeds, 1))
    return geo
  }, [count])

  const material = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader: smokeVertexShader,
        fragmentShader: smokeFragmentShader,
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        uniforms: {
          uTime: { value: 0 },
          uSize: { value: 190 },
          uPixelRatio: { value: dpr },
          uSpread: { value: spread },
          uOpacity: { value: opacity },
          uColor: { value: new THREE.Color('#8c7a58') },
        },
      }),
    [dpr, spread, opacity],
  )

  // Die Uniform wird direkt mutiert — kein Ref, kein Re-Render pro Frame.
  useFrame((_, delta) => {
    const time = material.uniforms['uTime']
    if (time) time.value += delta
  })

  // GPU-Speicher aufräumen, wenn die Szene entladen wird.
  useEffect(() => {
    return () => {
      geometry.dispose()
      material.dispose()
    }
  }, [geometry, material])

  return <points geometry={geometry} material={material} frustumCulled={false} />
}
