import next from 'eslint-config-next'
import coreWebVitals from 'eslint-config-next/core-web-vitals'
import typescript from 'eslint-config-next/typescript'
import prettier from 'eslint-config-prettier/flat'

/**
 * ESLint flat config。
 *
 * 原实现用 `FlatCompat` 去 extends 传统式的 `next` / `next/core-web-vitals` /
 * `next/typescript`，在 ESLint 9.39 + eslint-config-next 16 下会直接崩：
 *   TypeError: Converting circular structure to JSON
 *     ... property 'configs' -> ... property 'plugins' -> property 'react' closes the circle
 * 于是 `pnpm lint` 从来没跑通过（叠加 Next 16 移除 `next lint` 命令，CI 的 eslint
 * workflow 一直是失败的）。
 *
 * eslint-config-next@16 已原生导出 flat config（`/core-web-vitals`、`/typescript`），
 * 直接展开即可，不再需要 FlatCompat。
 *
 * `eslint-config-prettier/flat` 放在库配置之后用于关掉与 Prettier 冲突的格式规则；
 * 本文件后面的自定义 rules 仍在它之后，所以 `semi` / `quotes` 这类与格式化重叠的
 * 规则是**有意**保留的（项目约定：单引号、无分号）。
 */
const nextConfigs = [...next, ...coreWebVitals, ...typescript]

/**
 * 复用 eslint-config-next 内部已经加载的 react-hooks 插件实例。
 *
 * 不要自己 `import 'eslint-plugin-react-hooks'`：v7 会**再加载一份** React Compiler
 * 工具链，实测让 ESLint 堆内存涨到 4GB 后 OOM 崩溃（exit 134）。
 * flat config 又要求「在某对象里引用插件规则时该插件必须在同一对象中注册」，
 * 所以这里取出同一个实例注册到我们的覆盖对象上。
 */
const reactHooksPlugin = nextConfigs.find((c) => c?.name === 'next')?.plugins?.['react-hooks']

export default [
  ...nextConfigs,
  prettier,
  {
    // 仅在成功取得插件实例时才注册（取不到时下面的规则覆盖也就无从生效，
    // 宁可报错也不要静默失效）
    ...(reactHooksPlugin ? { plugins: { 'react-hooks': reactHooksPlugin } } : {}),
    rules: {
      'react/no-unescaped-entities': 'off',
      '@next/next/no-page-custom-font': 'off',
      'quotes': ['error', 'single'],
      'no-multiple-empty-lines': ['error', { max: 1 }],
      'semi': ['error', 'never'],

      // ---- 以下规则降级为 warn ----
      // 它们全部是 eslint-config-next@16 引入的新规则（多数来自 React Compiler），
      // 而命中的是既有代码里的历史模式。设为 error 会让 CI 长期红灯、失去信号价值；
      // 设为 warn 既能让 CI 恢复可用，又把这些位置暴露出来，待专门重构时逐项消除。
      //
      // - ban-ts-comment：13 处历史 @ts-ignore / 1 处 @ts-nocheck。
      //   正确做法是逐处确认后改成 @ts-expect-error 并补描述（@ts-expect-error 在
      //   "下一行恰好没报错" 时会反过来报错，所以不能脚本批量替换，需人工核对）。
      '@typescript-eslint/ban-ts-comment': 'warn',
      // - set-state-in-effect / preserve-manual-memoization：命中「在 effect 里
      //   setState 以同步 props 派生状态」这类既有写法。改成派生值或 key 重置属于
      //   行为等价重构，需要专门一轮验证，不宜夹在性能优化里做。
      'react-hooks/set-state-in-effect': 'warn',
      'react-hooks/preserve-manual-memoization': 'warn',
      // - 这两条是既有技术债的度量口径，保持 warn 以便看清规模
      '@typescript-eslint/no-explicit-any': 'warn',
      '@typescript-eslint/no-unused-vars': 'warn',
    },
  },
  {
    ignores: [
      '.next/**',
      'out/**',
      'build/**',
      'next-env.d.ts',
      // 本地依赖 store / corepack 缓存。它们位于项目目录内（沙箱限制下只能装到这里），
      // 里面是上千个包文件；不排除的话 ESLint 会去扫描它们，实测直接 4GB 堆 OOM。
      '.pnpm-store/**',
      '.corepack/**',
      // shadcn/ui 样板：原 `lint:fix` 脚本就用 --ignore-pattern 排除它
      'components/ui/**',
    ],
  },
]
