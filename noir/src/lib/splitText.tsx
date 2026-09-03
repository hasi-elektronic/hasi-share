import { Fragment, type ReactElement } from 'react'
import { WORD_INNER_CLASS } from './wordMask'

/**
 * Eigene Text-Aufteilung — kein GSAP-Club-Plugin.
 *
 * Jedes Wort wird in einen Maskenrahmen (`overflow: hidden`) gepackt und
 * bekommt ein inneres Element, das von außen animiert wird
 * (`.split-word__inner` von 100% Höhe nach 0).
 *
 * Wichtig für Screenreader: die Maskenstruktur wird per `aria-hidden`
 * ausgeblendet und der Originaltext als `sr-only`-Kopie ausgegeben, damit
 * kein Wort einzeln vorgelesen wird.
 */
type SplitWordsProps = {
  text: string
  className?: string
  wordClassName?: string
  /** Erzwingt einen Zeilenumbruch an dieser Stelle: "Zeile eins|Zeile zwei" */
  as?: 'span' | 'div'
}

export function SplitWords({
  text,
  className = '',
  wordClassName = '',
  as = 'span',
}: SplitWordsProps): ReactElement {
  const Tag = as
  const lines = text.split('|')

  return (
    <Tag className={className}>
      <span className="sr-only">{lines.join(' ')}</span>
      <span aria-hidden="true" className="block">
        {lines.map((line, lineIndex) => (
          <Fragment key={lineIndex}>
            {line
              .trim()
              .split(/\s+/)
              .map((word, wordIndex) => (
                <span
                  key={`${lineIndex}-${wordIndex}`}
                  className={`split-word inline-block overflow-hidden align-bottom ${wordClassName}`}
                >
                  <span className={`${WORD_INNER_CLASS} inline-block will-change-transform`}>
                    {word}
                  </span>
                  <span className="inline-block">&nbsp;</span>
                </span>
              ))}
            {lineIndex < lines.length - 1 ? <br /> : null}
          </Fragment>
        ))}
      </span>
    </Tag>
  )
}
