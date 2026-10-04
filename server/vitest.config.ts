import swc from 'unplugin-swc';
import { defineConfig } from 'vitest/config';

// Nest 依赖装饰器元数据做注入，esbuild 不产出，改用 swc 转译；e2e 需要 MySQL 与 Redis，启动方式见 README。
export default defineConfig({
  plugins: [swc.vite({ module: { type: 'es6' } })],
  resolve: { alias: { src: new URL('./src', import.meta.url).pathname } },
  test: {
    globals: true,
    include: ['test/**/*.test.ts'],
    setupFiles: ['test/setup_env.ts'],
    testTimeout: 30000,
    hookTimeout: 60000,
    fileParallelism: false,
  },
});
