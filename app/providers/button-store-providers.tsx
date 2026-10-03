'use client'

import { type ReactNode, createContext, useContext, useState } from 'react'
import { type StoreApi, useStore } from 'zustand'

import { type ButtonStore, createButtonStore, initButtonStore } from '~/stores/button-stores'

export const ButtonStoreContext = createContext<StoreApi<ButtonStore> | null>(
  null,
)

export interface ButtonStoreProviderProps {
  children: ReactNode
}

export const ButtonStoreProvider = ({
  children,
}: ButtonStoreProviderProps) => {
  // 用 useState 的惰性初始化代替 `useRef` + 渲染期赋值。
  // 后者会在渲染期间读写 ref，React Compiler 的 react-hooks/refs 规则会直接报错
  // （渲染必须保持纯粹，且并发渲染下渲染期写 ref 是不安全的）。
  // 这也正是 zustand 官方推荐的按请求创建 store 的写法。
  const [store] = useState(() => createButtonStore(initButtonStore()))

  return (
    <ButtonStoreContext.Provider value={store}>
      {children}
    </ButtonStoreContext.Provider>
  )
}

export const useButtonStore = <T,>(
  selector: (store: ButtonStore) => T,
): T => {
  const buttonStoreContext = useContext(ButtonStoreContext)

  if (!buttonStoreContext) {
    throw new Error('useButtonStore must be use within ButtonStoreProvider')
  }

  return useStore(buttonStoreContext, selector)
}
