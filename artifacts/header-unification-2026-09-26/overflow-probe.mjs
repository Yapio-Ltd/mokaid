import { chromium } from "../../node_modules/playwright/index.mjs";
import { writeFile } from "node:fs/promises";
const browser = await chromium.launch();
try {
 const page = await browser.newPage({ viewport: { width: 320, height: 900 } });
 await page.goto("http://127.0.0.1:5181/privacy", { waitUntil: "domcontentloaded" });
 await page.locator("[data-site-header]").waitFor();
 await page.evaluate(() => document.fonts.ready);
 const result=await page.evaluate(() => ({ width:innerWidth, scrollWidth:document.documentElement.scrollWidth, overflow:[...document.querySelectorAll("body *")].filter(el=>el.getBoundingClientRect().right>innerWidth+1).map(el=>({tag:el.tagName, class:el.className, width:el.getBoundingClientRect().width,right:el.getBoundingClientRect().right,text:el.textContent?.slice(0,160)})).slice(-25)}));
 await writeFile(new URL("overflow-privacy-320.json",import.meta.url),JSON.stringify(result,null,2));
 console.log(JSON.stringify(result,null,2));
} finally { await browser.close(); }
