/** Local Vite scene integration check without an API account.
 * Run with Vite running: node scripts/verify-office-transitions.mjs
 * Fixed simulation steps verify routes, not hardware FPS or visual rig quality.
 */
import { chromium } from "playwright";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const base = process.env.MOKAID_WEB_URL || "http://127.0.0.1:5173";
const out = fileURLToPath(new URL("../tmp-office-verify/", import.meta.url));
mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 640, height: 480 } });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.route("**/office-motion-fixture", route => route.fulfill({
    contentType: "text/html", body: `<!doctype html><style>html,body{margin:0;height:100%;background:#050507}canvas{width:100%;height:100%;display:block}</style><canvas></canvas><script type="module">
      import { OfficeScene } from '/src/three/office-scene.ts';
      window.agents = Array.from({length:6},(_,i)=>({id:'check-'+i,name:'Agent '+i,kind:'general',status:'active',presenceStatus:'online',visualState:'idle',color:'#b9a1ef',seatIndex:i,currentTaskTitle:null}));
      window.office = new OfficeScene(document.querySelector('canvas'),{onSelectAgent(){},onFps(){},onBubblePositions(){}});
      office.updateAgents(agents);
    </script>`,
  }));
  await page.goto(`${base}/office-motion-fixture`);
  await page.waitForFunction(() => window.office?.debugLocoSnapshot().crowdReady && window.office.debugLocoSnapshot().agents.length === 6, null, { timeout: 120_000 });
  const result = await page.evaluate(() => {
    const office = window.office;
    office.pause();
    office.engine.getDeltaTime = () => 1000 / 30;
    office.scene.useConstantAnimationDeltaTime = true;
    const snapshot = () => [...office.avatars.values()].map(a => ({
      slot: a.socketId, crowd: Boolean(a.crowdAgent), recover: a.recoverCount,
      blend: Boolean(a.socketBlend), exit: Boolean(a.socketExit),
    }));
    const step = () => {
      for (let frame = 0; frame < 1500; frame++) {
        for (const a of office.avatars.values()) if (a.socketBlend) a.socketBlend.start -= 1 / 30;
        office.animate(); office.scene._animate(1000 / 30);
      }
    };
    const seated = snapshot();
    const missions = [['coffee','coffee_active'],['sofa_main','sofa_a'],['sofa_main','sofa_c'],['foosball','foosball_b']];
    window.agents = window.agents.map((a,i) => missions[i] ? {...a,officePoiId:missions[i][0],officeSlotId:missions[i][1]} : a);
    office.updateAgents(window.agents); step();
    const activities = snapshot();
    window.agents = window.agents.map(a => ({...a,officePoiId:null,officeSlotId:null}));
    office.updateAgents(window.agents); step();
    const returned = snapshot();
    return { seated, activities, returned };
  });
  writeFileSync(`${out}transitions.json`, JSON.stringify(result, null, 2));
  assert.deepEqual(errors, [], "browser errors");
  for (let i = 0; i < 6; i++) {
    assert.equal(result.seated[i].slot, `desk_${i}`);
    assert.equal(result.seated[i].crowd, false, "seated bodies must not enter Detour");
    assert.equal(result.returned[i].slot, `desk_${i}`, "return to assigned chair");
    assert.equal(result.returned[i].recover, 0, "no recovery teleport");
  }
  assert.deepEqual(result.activities.slice(0,4).map(a=>a.slot), ['coffee_active','sofa_a','sofa_c','foosball_b']);
  for (const state of result.activities) {
    assert.equal(state.recover, 0); assert.equal(state.blend, false); assert.equal(state.exit, false);
  }
  console.log("PASS: six seated agents, four simultaneous activity routes, return to assigned chairs.");
} finally {
  await browser.close();
}
