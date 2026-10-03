import type { ExifType } from '~/types'
import { createId } from '@paralleldrive/cuid2'
import { extractCaptureTimeFromExifTags } from '~/lib/utils/exif-time'

/**
 * 廉价预判文件是否为 HEIC/HEIF，**不加载 heic-to**。
 *
 * 背景：`heic-to`（含 libheif wasm）与 `exifreader` 被打进同一个 2,828.9 KB 的 chunk，
 * 让 `/admin/upload` 首屏 JS 达到 4,040 KB（实测）。上传组件此前无条件 `await isHeic(file)`，
 * 而那会立刻把整个 heic-to 拉下来。绝大多数上传是 JPEG/PNG，用扩展名与 MIME 就能排除，
 * 于是把这个大 chunk 推迟到**真的**遇到 HEIC 时才加载。
 *
 * 预判为真时仍会用 heic-to 的 `isHeic` 复核，所以这里宁可宽进（假阳性只是多加载一次，
 * 假阴性才会漏掉转换），因此不放过任何 heic/heif 线索。
 */
export function looksLikeHeic(file: File): boolean {
  const name = file.name?.toLowerCase() ?? ''
  if (name.endsWith('.heic') || name.endsWith('.heif')) return true
  return /image\/hei[cf]/i.test(file.type ?? '')
}

/**
 * 权威判断是否为 HEIC —— 但**先过一遍廉价预判**，只有可能是 HEIC 时才加载 heic-to。
 *
 * 上传组件用这个替代直接 `await isHeic(file)`：后者会把 2.8MB 的 heic-to chunk
 * 在每次选择文件时都拉下来，哪怕选的是 JPEG。
 */
export async function isHeicFile(file: File): Promise<boolean> {
  if (!looksLikeHeic(file)) return false
  const { isHeic } = await import('heic-to')
  return await isHeic(file)
}

/**
 * 解析图片中的 exif 信息
 * @param file 文件
 *
 * 注：用什么库解析无所谓，但为了向后兼容，exif 参数名字还是根据 ExifType 进行匹配即可。
 */
export async function exifReader(file: ArrayBuffer | SharedArrayBuffer | Buffer) {
  // exifreader 约 1.1MB，只在真正解析 EXIF 时才加载
  const ExifReader = (await import('exifreader')).default
  const tags = await ExifReader.load(file)
  const exifObj = {
    make: '',
    model: '',
    bits: '',
    data_time: '',
    exposure_time: '',
    f_number: '',
    exposure_program: '',
    iso_speed_rating: '',
    focal_length: '',
    lens_specification: '',
    lens_model: '',
    exposure_mode: '',
    cfa_pattern: '',
    color_space: '',
    white_balance: '',
  } as ExifType
  exifObj.make = tags?.Make?.description
  exifObj.model = tags?.Model?.description
  exifObj.bits = tags?.['Bits Per Sample']?.description
  exifObj.data_time = extractCaptureTimeFromExifTags(tags as any)
  exifObj.exposure_time = tags?.ExposureTime?.description
  exifObj.f_number = tags?.FNumber?.description
  exifObj.exposure_program = tags?.ExposureProgram?.description
  exifObj.iso_speed_rating = tags?.ISOSpeedRatings?.description
  exifObj.focal_length = tags?.FocalLength?.description
  exifObj.lens_specification = tags?.LensSpecification?.description
  exifObj.lens_model = tags?.LensModel?.description
  exifObj.exposure_mode = tags?.ExposureMode?.description
  // @ts-expect-error CFAPattern is not included in the ExifReader types
  exifObj.cfa_pattern = tags?.CFAPattern?.description
  exifObj.color_space = tags?.ColorSpace?.description
  exifObj.white_balance = tags?.WhiteBalance?.description

  return {
    tags,
    exifObj
  }
}

/**
 * 上传 object 到对应的存储
 * @param file 文件 object 流
 * @param type 上传类型 '' | '/preview'
 * @param storage storage 存储类型
 * @param mountPath 文件挂载路径（目前只有 Open List 用得到
 */
export async function uploadFile(file: any, type: string, storage: string, mountPath: string) {
  const imageId = createId()
  // 获取文件后缀
  const ext = file.name.split('.').pop()
  const fileName= file.name
  // 生成新的文件名
  const newFileName = `${imageId}.${ext}`
  // 创建新的 File 对象
  const newFile = new File([file], newFileName, { type: file.type })
  // 如果是 Open List，使用旧的上传方式
  if (storage === 'openList') {
    const formData = new FormData()
    formData.append('file', newFile)
    formData.append('storage', storage)
    formData.append('type', type)
    if (mountPath) {
      formData.append('mountPath', mountPath)
    }

    const res = await fetch('/api/v1/file/upload', {
      method: 'POST',
      body: formData,
      credentials: 'include',
      headers: {
        'Accept': 'application/json',
      }
    }).then(res => res.json())

    if (res?.code === 200) {
      return {
        code: 200,
        data: {
          url: res?.data,
          imageId: imageId,
          fileName: fileName
        }
      }
    }
    throw new Error('Upload failed')
  }

  // 预签名 URL 上传方式
  const presignedResponse = await fetch('/api/v1/file/presigned-url', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      filename: newFile.name,
      contentType: newFile.type,
      type: type,
      storage: storage
    })
  }).then(res => res.json())

  if (presignedResponse?.code !== 200) {
    throw new Error('Failed to get presigned URL')
  }

  const { presignedUrl, key } = presignedResponse.data

  // 使用预签名 URL 上传文件
  try {
    const response = await fetch(presignedUrl, {
      method: 'PUT',
      body: newFile,
      headers: {
        'Content-Type': newFile.type,
      },
      credentials: 'omit'
    })

    if (!response.ok) {
      throw new Error(`Upload failed with status: ${response.status}`)
    }

    const getObjectResponse = await fetch('/api/v1/file/getObjectUrl', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        key: key,
        storage: storage
      })
    }).then(res => res.json())

    if (getObjectResponse?.code !== 200) {
      throw new Error('Failed to get object URL')
    }

    return {
      code: 200,
      data: {
        url: getObjectResponse?.data,
        imageId: imageId,
        fileName: fileName
      }
    }
  } catch (error) {
    console.error('Direct upload failed:', error)
    throw new Error('Upload failed')
  }
}
