import { useEffect, useRef } from 'react'

type SmartRefreshOptions = {
  enabled?: boolean
  intervalMs?: number
  minGapMs?: number
  refreshOnFocus?: boolean
}

export function useSmartRefresh(
  refresh: () => Promise<unknown> | unknown,
  {
    enabled = true,
    intervalMs = 0,
    minGapMs = 900,
    refreshOnFocus = true,
  }: SmartRefreshOptions = {},
) {
  const refreshRef = useRef(refresh)
  const runningRef = useRef(false)
  const lastRunRef = useRef(0)

  useEffect(() => {
    refreshRef.current = refresh
  }, [refresh])

  useEffect(() => {
    if (!enabled) return

    let disposed = false
    let timer: number | null = null

    const run = async () => {
      if (disposed || runningRef.current || document.visibilityState === 'hidden') return
      const now = Date.now()
      if (now - lastRunRef.current < minGapMs) return

      runningRef.current = true
      lastRunRef.current = now
      try {
        await refreshRef.current()
      } finally {
        runningRef.current = false
      }
    }

    const stopTimer = () => {
      if (timer !== null) {
        window.clearInterval(timer)
        timer = null
      }
    }

    const startTimer = () => {
      stopTimer()
      if (intervalMs > 0 && document.visibilityState === 'visible') {
        timer = window.setInterval(() => void run(), intervalMs)
      }
    }

    const onVisible = () => {
      if (document.visibilityState === 'visible') {
        startTimer()
        void run()
      } else {
        stopTimer()
      }
    }
    const onFocus = () => void run()
    const onOnline = () => void run()
    const onPageShow = () => void run()

    if (refreshOnFocus) {
      document.addEventListener('visibilitychange', onVisible)
      window.addEventListener('focus', onFocus)
      window.addEventListener('online', onOnline)
      window.addEventListener('pageshow', onPageShow)
    }

    startTimer()

    return () => {
      disposed = true
      stopTimer()
      document.removeEventListener('visibilitychange', onVisible)
      window.removeEventListener('focus', onFocus)
      window.removeEventListener('online', onOnline)
      window.removeEventListener('pageshow', onPageShow)
    }
  }, [enabled, intervalMs, minGapMs, refreshOnFocus])
}

export function scheduleIdle(task: () => void, timeout = 1400) {
  const idleWindow = window as Window & {
    requestIdleCallback?: (callback: () => void, options?: { timeout: number }) => number
    cancelIdleCallback?: (handle: number) => void
  }

  if (typeof idleWindow.requestIdleCallback === 'function') {
    const id = idleWindow.requestIdleCallback(task, { timeout })
    return () => idleWindow.cancelIdleCallback?.(id)
  }

  const id = globalThis.setTimeout(task, Math.min(timeout, 350))
  return () => globalThis.clearTimeout(id)
}
