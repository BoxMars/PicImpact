type ExifTagLike = {
  description?: unknown
}

type ExifTagsLike = Record<string, ExifTagLike | undefined>

/**
 * Normalize EXIF datetime into "YYYY:MM:DD HH:mm:ss".
 * Returns empty string when the value cannot be recognized.
 */
export function normalizeExifDateTime(input: unknown): string {
  if (typeof input !== 'string') {
    return ''
  }

  const raw = input.trim()
  if (!raw) {
    return ''
  }

  const match = raw.match(
    /^(\d{4})[-:](\d{2})[-:](\d{2})[ T](\d{2}):(\d{2}):(\d{2})/
  )

  if (!match) {
    return ''
  }

  const [, year, month, day, hour, minute, second] = match
  return `${year}:${month}:${day} ${hour}:${minute}:${second}`
}

export function extractCaptureTimeFromExifTags(tags: ExifTagsLike): string {
  const candidates = [
    tags?.DateTimeOriginal?.description,
    tags?.DateTimeDigitized?.description,
    tags?.DateTime?.description,
    tags?.CreateDate?.description,
  ]

  for (const candidate of candidates) {
    const normalized = normalizeExifDateTime(candidate)
    if (normalized) {
      return normalized
    }
  }

  return ''
}

/**
 * Format EXIF capture time for UI display.
 * Input: "YYYY:MM:DD HH:mm:ss" or compatible variants.
 * Output: "YYYY-MM-DD".
 */
export function formatExifDateTimeForDisplay(input: unknown): string {
  const normalized = normalizeExifDateTime(input)
  if (!normalized) {
    return typeof input === 'string' ? input : ''
  }

  return `${normalized.slice(0, 4)}-${normalized.slice(5, 7)}-${normalized.slice(8, 10)}`
}
