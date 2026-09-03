import { useState } from 'react'
import { IMAGE_WIDTHS, type ImageAsset } from '@/data/images'

type PictureProps = {
  image: ImageAsset
  sizes: string
  className?: string
  imgClassName?: string
  /** Bilder oberhalb der Falz laden eifrig, alles andere lazy. */
  priority?: boolean
}

const srcFor = (name: string, width: number) => `/img/${name}-${width}.webp`

/**
 * WebP mit Breitenvarianten, festen Maßen (CLS = 0) und LQIP-Unschärfe,
 * die beim Dekodieren des echten Bildes ausblendet.
 */
export function Picture({ image, sizes, className = '', imgClassName = '', priority }: PictureProps) {
  const [loaded, setLoaded] = useState(false)

  return (
    <div className={`relative overflow-hidden bg-elevated ${className}`}>
      <div
        aria-hidden="true"
        className="absolute inset-0 scale-110 bg-cover bg-center blur-xl transition-opacity duration-700 ease-noir"
        style={{
          backgroundImage: `url("${image.lqip}")`,
          opacity: loaded ? 0 : 1,
        }}
      />
      <picture>
        <source
          type="image/webp"
          sizes={sizes}
          srcSet={IMAGE_WIDTHS.map((w) => `${srcFor(image.name, w)} ${w}w`).join(', ')}
        />
        <img
          src={srcFor(image.name, 1280)}
          alt={image.alt}
          width={image.width}
          height={image.height}
          sizes={sizes}
          loading={priority ? 'eager' : 'lazy'}
          decoding="async"
          fetchPriority={priority ? 'high' : 'auto'}
          onLoad={() => setLoaded(true)}
          className={`h-full w-full object-cover transition-opacity duration-700 ease-noir ${
            loaded ? 'opacity-100' : 'opacity-0'
          } ${imgClassName}`}
        />
      </picture>
    </div>
  )
}
