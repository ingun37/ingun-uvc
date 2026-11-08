import { expect, test } from '@playwright/test';
import path from 'node:path';

const width = 1280;
const height = 720;

test.use({ viewport: { width, height }, deviceScaleFactor: 1 });

test('save thumbnail screenshot', async ({ page }) => {
  const params = new URLSearchParams({
    home: process.env.HOME_TEAM || 'DAL',
    away: process.env.AWAY_TEAM || 'CLE',
    image: process.env.BACKGROUND_IMAGE || 'sample-bg.jpg',
  });

  await page.goto(`/?${params}`);
  await expect(page.locator('.thumbnail')).toHaveCSS('width', `${width}px`);
  await expect(page.locator('.thumbnail')).toHaveCSS('height', `${height}px`);
  await page.locator('.thumbnail img').evaluateAll(async (images) => {
    await Promise.all(images.map(async (image) => {
      const img = image as HTMLImageElement;
      if (!img.complete) await new Promise<void>((resolve, reject) => {
        img.addEventListener('load', () => resolve(), { once: true });
        img.addEventListener('error', () => reject(new Error(`Failed to load ${img.src}`)), { once: true });
      });
      if (!img.naturalWidth) throw new Error(`Failed to load ${img.src}`);
    }));
  });

  const output = path.resolve(process.env.SCREENSHOT_PATH || 'thumbnail.png');
  const screenshot = await page.locator('.thumbnail').screenshot({ path: output });
  expect(screenshot.readUInt32BE(16)).toBe(width);
  expect(screenshot.readUInt32BE(20)).toBe(height);
  console.log(`Saved ${output}`);
});
