import useSWR from 'swr'
import type { ImageHandleProps } from '~/types/props'

export const useSwrPageTotalHook = ({ args, totalHandle, album, initialPageTotal }: ImageHandleProps)   => {
  const { data, error, isLoading, isValidating, mutate } = useSWR([args, album],
    () => {
      // Call with optional camera/lens parameters as undefined for backward compatibility
      return totalHandle(album, undefined, undefined)
    }, {
      fallbackData: initialPageTotal,
      revalidateOnFocus: false,
      revalidateIfStale: false,
      revalidateOnReconnect: false,
    })

  return {
    data,
    error,
    isLoading: isLoading || isValidating,
    mutate
  }
}
