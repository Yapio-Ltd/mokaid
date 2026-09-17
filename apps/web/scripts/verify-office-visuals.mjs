/** Render the real catalog locally, without an API session or workspace data.
 * MOKAID_BROWSER_CHANNEL=chrome node scripts/verify-office-visuals.mjs
 */
import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
const base = process.env.MOKAID_WEB_URL || 'http://127.0.0.1:5173';
const out = fileURLToPath(new URL('../tmp-office-verify/', import.meta.url));
await mkdir(out, { recursive: true });
const catalog = await readFile(new URL('../../api/lib/mokaid/assets_3d.ex', import.meta.url), 'utf8');
const avatars = [...catalog.matchAll(/"slug" => "(avatar_\w+)"[\s\S]*?"cdn_path" => "([^"]+)"/g)]
  .map(([, slug, path]) => ({ slug, path }));
assert.equal(avatars.length, 7, 'all seven catalog avatars must be rendered');
const browser = await chromium.launch({ headless: true, channel: process.env.MOKAID_BROWSER_CHANNEL });
const results = [];
try {
  for (const viewport of [{ width: 1440, height: 900 }, { width: 1024, height: 768 }]) {
    const page = await browser.newPage({ viewport });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/office-visual-fixture', route => route.fulfill({
      contentType: 'text/html', body: `<!doctype html><style>html,body{margin:0;height:100%;background:#050507}canvas{width:100%;height:100%;display:block}</style><canvas></canvas><script type="module">
        import { OfficeScene } from '/src/three/office-scene.ts';
        const catalog = ${JSON.stringify(avatars)};
        window.office = new OfficeScene(document.querySelector('canvas'),{onSelectAgent(){},onFps(){},onBubblePositions(){}});
        office.updateAgents(catalog.map((a,i)=>({id:a.slug,name:a.slug,kind:'general',status:'active',presenceStatus:'online',visualState:'working',color:'#ffffff',seatIndex:i,currentTaskTitle:null,avatarCdnPath:a.path})));
      </script>`,
    }));
    await page.goto(`${base}/office-visual-fixture`);
    await page.waitForFunction(() => window.office?.debugLocoSnapshot().agents.length === 7, null, { timeout: 120_000 });
    // Allow the crossfade and the first complete GPU frame to settle.
    await page.waitForTimeout(800);
    const state = await page.evaluate(() => [...office.avatars.values()].map(a => ({
      id: a.agent.id, clip: a.currentAnim, clips: Object.entries(a.anims).filter(([, group]) => !!group).map(([name]) => name),
      position: [a.root.position.x, a.root.position.y, a.root.position.z],
      skinned: a.meshes.some(m => !!m.skeleton),
      materials: [...new Set(a.meshes.map(m => m.material).filter(Boolean))].map(m => ({
        metallic: m.metallic, roughness: m.roughness,
        emission: m.emissiveColor?.asArray() ?? [0, 0, 0],
      })),
    })));
    assert.equal(state.length, 7);
    for (const avatar of state) {
      assert(avatar.skinned, `${avatar.id}: real skin must load`);
      for (const clip of ['walking', 'sitting', 'sitting_sofa', 'working', 'preparing_coffee', 'playing_foosball'])
        assert(avatar.clips.includes(clip), `${avatar.id}: ${clip} must be present`);
      assert(avatar.position.every(Number.isFinite), `${avatar.id}: finite socket`);
      for (const material of avatar.materials) {
        assert.equal(material.metallic, 0, `${avatar.id}: skin and clothing must not be metallic`);
        assert(material.roughness >= .65 - 1e-6, `${avatar.id}: soft material highlights`);
        assert(material.emission.every(value => value === 0), `${avatar.id}: clothing must not emit`);
      }
    }
    assert.deepEqual(errors, [], 'no browser exceptions');
    await page.screenshot({ path: `${out}office-${viewport.width}.png` });
    await page.evaluate(() => office.updateAgents([...office.avatars.values()].map((a, i) => ({
      ...a.agent, visualState: ['away', 'offline', 'celebrating'][i % 3],
    }))));
    await page.waitForFunction(() => [...office.avatars.values()].every(a => a.currentAnim === 'sitting'));
    assert.deepEqual(errors, [], 'desk status changes must not throw');
    if (viewport.width === 1440) {
      await page.evaluate(() => {
        office.debugSitOnSofa('sofa_b');
        const c = office.centerOffset;
        const target = office.camera.position.clone().set(1.99 - c.x, .9 - c.y, -5.78 - c.z);
        const direction = office.camera.position.subtract(office.camera.getTarget()).normalize();
        office.cameraPlacementOverride = true;
        office.camera.unfreezeProjectionMatrix();
        office.camera.getProjectionMatrix(true);
        office.camera.position.copyFrom(target.add(direction.scale(5)));
        office.camera.setTarget(target);
      });
      await page.waitForTimeout(900);
      await page.screenshot({ path: `${out}sofa-detail.png` });
    }
    assert.deepEqual(errors, [], 'no errors during visual inspection');
    results.push({ viewport, avatars: state, errors });
    await page.close();
  }
  await writeFile(`${out}visuals.json`, JSON.stringify(results, null, 2));
  console.log('PASS: seven real skinned catalog avatars, required activity clips, desktop and tablet rendering.');
} finally {
  await browser.close();
}
