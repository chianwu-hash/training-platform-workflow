import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

export function installSkill(skillsRoot) {
  const repoRoot = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
  const root = path.resolve(skillsRoot);
  const destination = path.join(root, 'training-platform-workflow');
  const manifestPath = path.join(destination, 'references', 'repo-location.json');
  const repository = 'https://github.com/chianwu-hash/training-platform-workflow';
  const skillSource = path.join(repoRoot, 'skills', 'training-platform-workflow', 'SKILL.md');
  for (const file of ['README.md', 'AGENTS.md', 'docs/SOP.md', 'src/runner.js']) {
    if (!fs.existsSync(path.join(repoRoot, file))) throw Error('repo 不完整，請重新下載');
  }
  if (fs.existsSync(destination)) {
    if (fs.lstatSync(destination).isSymbolicLink()) throw Error('同名 skill 是連結，請先人工核對');
    let previous;
    try { previous = JSON.parse(fs.readFileSync(manifestPath, 'utf8')); } catch { throw Error('同名 skill 非本安裝器管理，不予覆寫'); }
    if (previous.managedBy !== 'training-platform-workflow/skill-installer-v1' || previous.repository !== repository) throw Error('同名 skill 來源不符，不予覆寫');
  }
  fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
  fs.writeFileSync(path.join(destination, 'SKILL.md'), fs.readFileSync(skillSource, 'utf8'), 'utf8');
  fs.writeFileSync(manifestPath, JSON.stringify({ managedBy: 'training-platform-workflow/skill-installer-v1', repository, repoRoot }, null, 2) + '\n', 'utf8');
  return destination;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.length && (args[0] !== '--skills-root' || args.length !== 2)) throw Error('用法：npm run skill:install -- [--skills-root 技能根目錄]');
    const root = args[1] || path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'skills');
    const destination = installSkill(root);
    console.log(`技能已安裝：${destination}\n重新啟動 Codex 或開啟新對話後，使用 $training-platform-workflow。`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
