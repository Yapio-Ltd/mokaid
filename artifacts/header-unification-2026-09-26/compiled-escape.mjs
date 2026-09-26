import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { chromium } from "../../node_modules/playwright/index.mjs";
const origin = process.argv[2] || "http://127.0.0.1:4173";
const browser = await chromium.launch();
const report = { origin, status: "pending", checks: [], setup: "Compiled header only. Isolated mobile browser; MP4 aborted; download release returns404; no login or API writes." };
try {
 const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
 await context.addInitScript(() => localStorage.setItem("mokaid_cookie_consent", "rejected"));
 await context.route("**/*.mp4", route => route.abort());
 await context.route("https://downloads.mokaid.com/**", route => route.fulfill({ status:404, body:"Header test" }));
 const page = await context.newPage();
 for (const path of ["/", "/download", "/privacy"]) {
   await page.goto(new URL(path, origin).href, { waitUntil:"load" });
   const header=page.locator("[data-site-header]");
   const summary=header.locator("summary");
   await summary.waitFor({ state:"visible" });
   await page.evaluate(() => document.fonts.ready);
   // Do not wait for React's native-toggle state update: Escape must work as
   // soon as the disclosure is open.
   await summary.click();
   await page.keyboard.press("Escape");
   await page.waitForFunction(() => !document.querySelector("[data-site-header] details").open);
   assert.equal(await summary.evaluate(el=>el===document.activeElement),true);
   assert.equal(await header.getByRole("navigation",{name:"Mobile",exact:true}).isVisible(),false);
   report.checks.push(`${path}: immediate Escape closes native menu and restores focus`);
 }
 report.status="passed";
} catch(error) {report.status="failed";report.error=String(error.stack||error);process.exitCode=1;}
finally {await browser.close();await writeFile(new URL("compiled-escape.json",import.meta.url),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));}
