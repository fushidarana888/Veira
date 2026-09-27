import { useEffect, useRef } from 'react'
import type { Dispatch, SetStateAction } from 'react'

const SLOW_ACTION_MS = 2600

export function useActionGate<T>(
  setBusy: Dispatch<SetStateAction<T>>,
  idleValue: T,
  setMessage?: Dispatch<SetStateAction<string>>,
) {
  const lockedRef = useRef(false)
  const slowTimerRef = useRef<number | null>(null)

  function clearSlowTimer() {
    if (slowTimerRef.current !== null) {
      window.clearTimeout(slowTimerRef.current)
      slowTimerRef.current = null
    }
  }

  function beginAction(busyValue: T, initialMessage?: string) {
    if (lockedRef.current) return false

    lockedRef.current = true
    setBusy(busyValue)

    if (setMessage) {
      if (initialMessage !== undefined) setMessage(initialMessage)
      slowTimerRef.current = window.setTimeout(() => {
        setMessage((current) => {
          const notice = 'Сервер отвечает дольше обычного — запрос всё ещё выполняется, повторно нажимать не нужно.'
          if (current.includes(notice)) return current
          return current ? current + ' ' + notice : notice
        })
      }, SLOW_ACTION_MS)
    }

    return true
  }

  function endAction() {
    clearSlowTimer()
    lockedRef.current = false
    setBusy(idleValue)
  }

  useEffect(() => () => clearSlowTimer(), [])

  return {
    beginAction,
    endAction,
    isActionLocked: () => lockedRef.current,
  }
}
