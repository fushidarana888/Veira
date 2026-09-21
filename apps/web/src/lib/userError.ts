export function userFacingError(
  raw: unknown,
  fallback = 'Не удалось выполнить действие. Попробуй ещё раз.',
) {
  const message = typeof raw === 'string' ? raw.trim() : ''

  if (!message) return fallback

  const lower = message.toLowerCase()

  if (
    lower.includes('failed to fetch')
    || lower.includes('networkerror')
    || lower.includes('network request failed')
    || lower.includes('load failed')
  ) {
    return 'Не удалось связаться с сервером. Проверь соединение и попробуй ещё раз.'
  }

  if (
    lower.includes('invalid login credentials')
    || lower.includes('invalid email or password')
  ) {
    return 'Неверный email или пароль.'
  }

  if (lower.includes('user already registered')) {
    return 'Аккаунт с такой почтой уже существует.'
  }

  if (
    lower.includes('invalid email')
    || lower.includes('unable to validate email address')
  ) {
    return 'Укажи корректный email.'
  }

  if (
    lower.includes('password should be at least')
    || lower.includes('password is too short')
  ) {
    return 'Пароль слишком короткий.'
  }

  if (
    lower.includes('rate limit')
    || lower.includes('too many requests')
  ) {
    return 'Слишком много запросов. Подожди немного и попробуй ещё раз.'
  }

  if (
    lower.includes('jwt expired')
    || lower.includes('invalid jwt')
    || lower.includes('auth session missing')
    || lower.includes('refresh token')
  ) {
    return 'Сессия истекла. Войди в аккаунт ещё раз.'
  }

  if (
    lower.includes('permission denied')
    || lower.includes('insufficient_privilege')
    || lower.includes('42501')
    || lower.includes('row-level security')
  ) {
    return 'Эта часть игры временно недоступна. Обнови страницу и попробуй ещё раз.'
  }

  if (
    lower.includes('schema cache')
    || lower.includes('could not find the function')
    || lower.includes('could not find the table')
    || lower.includes('pgrst')
  ) {
    return 'Не удалось загрузить данные игры. Обнови страницу и попробуй ещё раз.'
  }

  if (
    /\b(sqlstate|constraint|duplicate key|null value|invalid input syntax|relation .+ does not exist|function .+ does not exist|column .+ does not exist|operator does not exist|stack depth|syntax error)\b/i.test(message)
  ) {
    return fallback
  }

  if (/^[A-Z][A-Z0-9_]{3,}$/.test(message)) {
    return fallback
  }

  if (message.length > 260) {
    return fallback
  }

  // Русские игровые сообщения безопасно показываем как есть.
  if (/[А-Яа-яЁё]/.test(message)) {
    return message
  }

  // Англоязычный backend-текст игроку не показываем.
  return fallback
}
