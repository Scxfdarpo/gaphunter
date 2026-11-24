// Frame capture for the GapHunter demo video: steps the page's
// deterministic timeline at 8 fps and screenshots every frame.
import puppeteer from 'puppeteer';
import { mkdirSync } from 'node:fs';

const FPS = 8, DUR = 84, OUT = '/tmp/ghframes';
mkdirSync(OUT, { recursive: true });
const browser = await puppeteer.launch({ args: ['--no-sandbox', '--force-color-profile=srgb'] });
const page = await browser.newPage();
await page.setViewport({ width: 1280, height: 720, deviceScaleFactor: 1 });
await page.goto('file:///home/hatch/workspace/dorahacks/reactive-omni/gaphunter/demo/demo.html', { waitUntil: 'load' });
const frames = FPS * DUR;
for (let i = 0; i < frames; i++) {
  await page.evaluate((t) => window.__seek(t), i / FPS);
  await page.screenshot({ path: `${OUT}/f${String(i).padStart(4, '0')}.png` });
  if (i % 80 === 0) console.log('frame', i, '/', frames);
}
await browser.close();
console.log('done', frames);
