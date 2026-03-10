import useSWR from 'swr'
import type { HandleProps } from '~/types/props'

export const useSwrHydrated = ({ handle, args }: HandleProps, fallbackData?: any)   => {
  const { data, error, isLoading, isValidating, mutate } = useSWR(args,
    () => {
      return handle()
    }, {
      revalidateOnFocus: false,
      revalidateIfStale: false,
      revalidateOnReconnect: false,
      fallbackData,
    })

  return {
    data,
    error,
    isLoading: isLoading || isValidating,
    mutate
  }
}
