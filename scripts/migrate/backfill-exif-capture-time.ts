import ExifReader from 'exifreader'
import { PrismaClient } from '@prisma/client'
import { extractCaptureTimeFromExifTags } from '../../lib/utils/exif-time'

type CliOptions = {
  apply: boolean
  limit: number
  concurrency: number
}

function parseArgs(argv: string[]): CliOptions {
  const apply = argv.includes('--apply')
  const limitArg = argv.find(arg => arg.startsWith('--limit='))
  const concurrencyArg = argv.find(arg => arg.startsWith('--concurrency='))

  const limit = limitArg ? Number.parseInt(limitArg.split('=')[1], 10) : 0
  const concurrency = concurrencyArg ? Number.parseInt(concurrencyArg.split('=')[1], 10) : 3

  return {
    apply,
    limit: Number.isNaN(limit) ? 0 : Math.max(0, limit),
    concurrency: Number.isNaN(concurrency) ? 3 : Math.max(1, concurrency),
  }
}

async function readCaptureTimeFromUrl(url: string): Promise<string> {
  const response = await fetch(url)
  if (!response.ok) {
    throw new Error(`Download failed: HTTP ${response.status}`)
  }
  const buffer = await response.arrayBuffer()
  const tags = await ExifReader.load(buffer)
  return extractCaptureTimeFromExifTags(tags as any)
}

async function run() {
  const options = parseArgs(process.argv.slice(2))
  const prisma = new PrismaClient()

  try {
    const rows = await prisma.images.findMany({
      where: {
        del: 0,
        OR: [
          { exif: { path: ['data_time'], equals: null } },
          { exif: { path: ['data_time'], equals: '' } },
        ] as any,
      },
      orderBy: {
        createdAt: 'desc',
      },
      select: {
        id: true,
        url: true,
        exif: true,
      },
      ...(options.limit > 0 ? { take: options.limit } : {}),
    })

    console.log(
      `[backfill-exif-capture-time] target_rows=${rows.length} mode=${options.apply ? 'apply' : 'dry-run'} concurrency=${options.concurrency}`
    )

    let processed = 0
    let updated = 0
    let skipped = 0
    let failed = 0

    let cursor = 0
    const workers = Array.from({ length: options.concurrency }, async () => {
      while (true) {
        const index = cursor
        cursor += 1
        if (index >= rows.length) {
          return
        }

        const row = rows[index]
        processed += 1

        try {
          const captureTime = await readCaptureTimeFromUrl(row.url)
          if (!captureTime) {
            skipped += 1
            console.log(`[skip] id=${row.id} reason=no-capture-time`)
            continue
          }

          const exif = (row.exif ?? {}) as Record<string, unknown>
          const nextExif = {
            ...exif,
            data_time: captureTime,
            date_time: captureTime,
          }

          if (options.apply) {
            await prisma.images.update({
              where: { id: row.id },
              data: { exif: nextExif as any },
            })
          }

          updated += 1
          console.log(`[ok] id=${row.id} capture_time=${captureTime}${options.apply ? '' : ' (dry-run)'}`)
        } catch (error) {
          failed += 1
          const message = error instanceof Error ? error.message : String(error)
          console.log(`[error] id=${row.id} reason=${message}`)
        }
      }
    })

    await Promise.all(workers)

    console.log(
      `[backfill-exif-capture-time] done processed=${processed} updated=${updated} skipped=${skipped} failed=${failed}`
    )
  } finally {
    await prisma.$disconnect()
  }
}

run().catch((error) => {
  console.error('[backfill-exif-capture-time] fatal', error)
  process.exit(1)
})
