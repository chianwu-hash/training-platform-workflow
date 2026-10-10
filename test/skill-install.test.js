import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { installSkill } from '../scripts/install-skill.js';

test('技能可安裝、更新並指向本機 repo，保留額外檔案', () => {
  const root = path.resolve('runtime', `skill-test-${process.pid}-${Date.now()}`);
  const destination = installSkill(root);
  const manifest = JSON.parse(fs.readFileSync(path.join(destination, 'references/repo-location.json'), 'utf8'));
  assert.equal(manifest.repoRoot, path.resolve('.'));
  assert.ok(fs.existsSync(path.join(manifest.repoRoot, 'docs/SOP.md')));
  fs.writeFileSync(path.join(destination, 'keep.txt'), '保留');
  assert.equal(installSkill(root), destination);
  assert.equal(fs.readFileSync(path.join(destination, 'keep.txt'), 'utf8'), '保留');
});
test('既有非受管理同名 skill 不會被覆寫', () => {
  const root = path.resolve('runtime', `skill-existing-${process.pid}-${Date.now()}`);
  const destination = path.join(root, 'training-platform-workflow');
  fs.mkdirSync(destination, { recursive: true });
  fs.writeFileSync(path.join(destination, 'SKILL.md'), '既有內容');
  assert.throws(() => installSkill(root), /不予覆寫/);
  assert.equal(fs.readFileSync(path.join(destination, 'SKILL.md'), 'utf8'), '既有內容');
});
