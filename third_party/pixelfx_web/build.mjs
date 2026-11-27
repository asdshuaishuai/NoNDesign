#!/usr/bin/env node
// 打包 pixelfx 特效子集（页面用 IIFE，全局 NAN_PIXELFX）。
//
// 产物：app/assets/pixelfx/pixelfx.min.js（确定性、无时间戳），
//       并更新 app/assets/pixelfx/build-manifest.json 的 files 里的 bundle 条目。
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..', '..');
const outDir = join(repoRoot, 'app', 'assets', 'pixelfx');

const pkg = JSON.parse(readFileSync(join(here, 'package.json'), 'utf8'));
const esbuildPkg = JSON.parse(
  readFileSync(join(here, 'node_modules', 'esbuild', 'package.json'), 'utf8'),
);
if (pkg.devDependencies.esbuild !== esbuildPkg.version) {
  throw new Error(`esbuild 版本漂移：package.json=${pkg.devDependencies.esbuild} installed=${esbuildPkg.version}`);
}

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

const result = await esbuild.build({
  entryPoints: [join(here, 'entry.js')],
  outdir: outDir,
  bundle: true,
  format: 'iife',
  globalName: 'NAN_PIXELFX',
  platform: 'browser',
  target: ['es2020'],
  minify: true,
  legalComments: 'none',
  write: false,
  charset: 'utf8',
});
const jsFile = result.outputFiles.find((file) => file.path.endsWith('.js'));
if (!jsFile) throw new Error('esbuild 没有产出 JS');
const bundle = jsFile.text;
if (bundle.includes('</script')) {
  throw new Error('pixelfx bundle 含 </script 序列，不能内联');
}
const outPath = join(outDir, 'pixelfx.min.js');
writeFileSync(outPath, bundle);

// 更新清单：删掉旧 bundle 条目后追加新条目（保持确定性顺序）。
const manifestPath = join(outDir, 'build-manifest.json');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
manifest.files = manifest.files.filter((entry) => entry.file !== 'pixelfx.min.js');
manifest.files.push({
  file: 'pixelfx.min.js',
  bytes: statSync(outPath).size,
  sha256: sha256(bundle),
});
writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

console.log(`pixelfx.min.js: ${(statSync(outPath).size / 1024).toFixed(1)} KiB`);
console.log(`sha256: ${sha256(bundle)}`);
