// 本地开发：node 作父进程（Ctrl+C 关停日志不乱码），swc 监听编译到 dist，bun --watch 跑编译产物、产物变化自动重启。
import { execSync, spawn } from 'node:child_process';

// 先完整编译一次，bun 启动时 dist 已就绪。
execSync('npm run build', { stdio: 'inherit' });

const children = [
  spawn('npx', ['swc', 'src', '-d', 'dist', '--strip-leading-paths', '--watch'], { stdio: 'inherit' }),
  spawn('bun', ['--watch', 'dist/main.js'], { stdio: 'inherit' }),
];

const stop = () => {
  for (const child of children) child.kill('SIGTERM');
  process.exit(0);
};

process.on('SIGINT', stop);
process.on('SIGTERM', stop);
