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

    const onVisible = () => {
      if (document.visibilityState === 'visible') void run()
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

    const timer = intervalMs > 0
      ? window.setInterval(() => void run(), intervalMs)
      : null

    return () => {
      disposed = true
      if (timer !== null) window.clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisible)
      window.removeEventListener('focus', onFocus)
      window.removeEventListener('online', onOnline)
      window.removeEventListener('pageshow', onPageShow)
    }
  }, [enabled, intervalMs, minGapMs, refreshOnFocus])
}

export function scheduleIdle(task: () => void, timeout = 1400) {
  if ('requestIdleCallback' in window) {
    const id = window.requestIdleCallback(task, { timeout })
    return () => window.cancelIdleCallback(id)
  }

  const id = window.setTimeout(task, Math.min(timeout, 350))
  return () => window.clearTimeout(id)
}
