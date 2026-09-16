// Shared file-granularity boundary after fm_build_output_target's Git checks.
// Symlinks are never followed or deleted; special files are also excluded.
// Any .git entry protects its containing directory and all descendants.
// These exclusions leave other regular files eligible in both cleanup paths.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

function scan(root) {
  const files = [], directories = [];
  function visit(p) {
    const s = fs.lstatSync(p);
    if (s.isSymbolicLink()) return;
    if (s.isDirectory()) {
      const names = fs.readdirSync(p);
      if (names.includes('.git')) return;
      for (const name of names) visit(path.join(p, name));
      directories.push(p);
    } else if (s.isFile()) {
      files.push({p, size:s.size, time:s.mtimeMs, ino:s.ino, dev:s.dev, blocks:s.blocks});
    }
  }
  if (fs.existsSync(root)) visit(root);
  return {files, directories};
}
export const files = root => scan(root).files;
export const directories = root => scan(root).directories;

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [root, mode] = process.argv.slice(2);
  if (!['dry-run','delete'].includes(mode)) throw Error('invalid prune mode');
  const output = scan(root);
  const size = Math.ceil(output.files.reduce((sum, f) => sum + f.blocks * 512, 0) / 1024);
  if (mode === 'delete') {
    for (const f of output.files) {
      const now = fs.lstatSync(f.p);
      if (!now.isFile() || now.ino !== f.ino || now.dev !== f.dev || now.size !== f.size || now.mtimeMs !== f.time)
        throw Error('artifact-changed');
      fs.unlinkSync(f.p);
    }
    for (const p of output.directories) {
      try { fs.rmdirSync(p); }
      catch (e) { if (!['ENOTEMPTY','EEXIST'].includes(e.code)) throw e; }
    }
  }
  console.log(`${mode === 'dry-run' ? 'would prune' : 'pruned'} ${root} (${size} KiB)`);
}
