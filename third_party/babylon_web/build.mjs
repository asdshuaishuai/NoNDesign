#!/usr/bin/env node
// 打包 3D 视频预览的 Babylon 降级渲染面（tree-shaken @babylonjs/core）。
//
// 产物（提交进仓库，确定性）：
//   app/assets/babylon/babylon.min.js       IIFE，全局名 NAN_BABYLON
//   app/assets/babylon/build-manifest.json  锁定版本 + 每份产物 sha256/字节数
//
// 纪律：
//  * 依赖版本在 package.json 里精确锁定，并与 node_modules 实装版本逐字核对；
//  * 产物不写时间戳/主机路径（同输入同字节，可复验）；
//  * 只打包我们真实用到的 Babylon 子集（Engine/Scene/相机/网格/标准材质/灯光），
//    **不引入 Babylon 的完整 UMD（9.x 完整包 ~8.9MB，会让预览页膨胀到不可用）**。
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..', '..');
const outDir = join(repoRoot, 'app', 'assets', 'babylon');

const pkg = JSON.parse(readFileSync(join(here, 'package.json'), 'utf8'));
const installed = (name) =>
  JSON.parse(
    readFileSync(join(here, 'node_modules', name, 'package.json'), 'utf8'),
  );
const pinned = {
  '@babylonjs/core': pkg.dependencies['@babylonjs/core'],
  esbuild: pkg.devDependencies.esbuild,
};
const actual = {
  '@babylonjs/core': installed('@babylonjs/core').version,
  esbuild: installed('esbuild').version,
};
for (const name of Object.keys(pinned)) {
  if (pinned[name] !== actual[name]) {
    throw new Error(
      `${name} 版本漂移：package.json=${pinned[name]} installed=${actual[name]}`,
    );
  }
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

const result = await esbuild.build({
  entryPoints: [join(here, 'entry.js')],
  outdir: outDir,
  bundle: true,
  format: 'iife',
  globalName: 'NAN_BABYLON',
  platform: 'browser',
  target: ['es2020'],
  minify: true,
  legalComments: 'none',
  write: false,
  charset: 'utf8',
});
const jsFile = result.outputFiles.find((file) => file.path.endsWith('.js'));
if (!jsFile) {
  throw new Error(
    'esbuild 没有产出 JS；实际产物：' +
      result.outputFiles.map((file) => file.path).join(', '),
  );
}
const bundle = jsFile.text;
if (bundle.includes('</script')) {
  // 产物会被内联进单文件页面的 <script>：出现结束标签序列就会把页面切断。
  throw new Error('babylon bundle 含 </script 序列，不能内联');
}

mkdirSync(outDir, { recursive: true });
const jsPath = join(outDir, 'babylon.min.js');
writeFileSync(jsPath, bundle);

const manifest = {
  schema: 'nan.babylon_web/1',
  source: 'npm:@babylonjs/core (tree-shaken minimal renderer)',
  versions: {
    '@babylonjs/core': pinned['@babylonjs/core'],
    esbuild: pinned.esbuild,
    babylonReported: '9.38.0',
  },
  entry: {
    file: 'third_party/babylon_web/entry.js',
    sha256: sha256(readFileSync(join(here, 'entry.js'))),
  },
  files: [
    {
      file: 'babylon.min.js',
      bytes: statSync(jsPath).size,
      sha256: sha256(bundle),
    },
  ],
};
writeFileSync(
  join(outDir, 'build-manifest.json'),
  `${JSON.stringify(manifest, null, 2)}\n`,
);

const kb = (statSync(jsPath).size / 1024).toFixed(1);
console.log(`babylon.min.js: ${kb} KiB`);
console.log(`sha256: ${manifest.files[0].sha256}`);
