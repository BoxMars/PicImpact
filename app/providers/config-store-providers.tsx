'use client'

import { type ReactNode, createContext, useContext, useState } from 'react'
import { type StoreApi, useStore } from 'zustand'

import { type ConfigStore, createConfigStore, initConfigStore } from '~/stores/config-stores'

export const ConfigStoreContext = createContext<StoreApi<ConfigStore> | null>(
  null,
)

export interface ConfigStoreProviderProps {
  children: ReactNode
}

export const ConfigStoreProvider = ({
  children,
}: ConfigStoreProviderProps) => {
  // 用 useState 的惰性初始化代替 `useRef` + 渲染期赋值。
  // 后者会在渲染期间读写 ref，React Compiler 的 react-hooks/refs 规则会直接报错
  // （渲染必须保持纯粹，且并发渲染下渲染期写 ref 是不安全的）。
  // 这也正是 zustand 官方推荐的按请求创建 store 的写法。
  const [store] = useState(() => createConfigStore(initConfigStore()))

  return (
    <ConfigStoreContext.Provider value={store}>
      {children}
    </ConfigStoreContext.Provider>
  )
}

export const useConfigStore = <T,>(
  selector: (store: ConfigStore) => T,
): T => {
  const configStoreContext = useContext(ConfigStoreContext)

  if (!configStoreContext) {
    throw new Error('useConfigStore must be use within ConfigStoreProvider')
  }

  return useStore(configStoreContext, selector)
}
