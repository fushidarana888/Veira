import { StrictMode } from 'react'
import { Capacitor } from '@capacitor/core'
import { App as NativeApp } from '@capacitor/app'
import { SplashScreen } from '@capacitor/splash-screen'
import { StatusBar, Style } from '@capacitor/status-bar'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import './styles.css'

const nativePlatform = Capacitor.isNativePlatform()

if (nativePlatform) {
  document.documentElement.classList.add('native-app')

  const connectionBanner = document.createElement('div')
  connectionBanner.className = 'native-connection-banner'
  connectionBanner.setAttribute('role', 'status')
  connectionBanner.setAttribute('aria-live', 'polite')
  connectionBanner.textContent = 'Нет соединения · Veira ждёт сеть'
  connectionBanner.hidden = navigator.onLine
  document.body.appendChild(connectionBanner)

  const syncConnectionBanner = () => {
    connectionBanner.hidden = navigator.onLine
  }

  window.addEventListener('online', syncConnectionBanner)
  window.addEventListener('offline', syncConnectionBanner)

  void StatusBar.setStyle({ style: Style.Light })
  void StatusBar.setBackgroundColor({ color: '#0b0e13' })
  void StatusBar.setOverlaysWebView({ overlay: false })

  void NativeApp.addListener('backButton', async () => {
    const event = new Event('veira:native-back', { cancelable: true })
    const unhandled = window.dispatchEvent(event)

    if (unhandled) {
      await NativeApp.exitApp()
    }
  })
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)

if (nativePlatform) {
  window.setTimeout(() => {
    void SplashScreen.hide()
  }, 350)
}

if (import.meta.env.PROD && !nativePlatform && 'serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    window.setTimeout(() => {
      void navigator.serviceWorker.register(import.meta.env.BASE_URL + 'sw.js')
    }, 1200)
  }, { once: true })
}
