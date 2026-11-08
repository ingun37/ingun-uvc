import { createServer } from 'node:http'
import { readFile, writeFile } from 'node:fs/promises'
import { resolve, extname, join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { chromium } from '@playwright/test'

const [background, home, away, destination] = process.argv.slice(2)
if (!background || !home || !away || !destination) {
  throw new Error('Usage: node render-thumbnail.mjs BACKGROUND HOME AWAY OUTPUT')
}
const dist = resolve(dirname(fileURLToPath(import.meta.url)), 'dist')
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg' }
const server = createServer(async (request, response) => {
  try {
    const path = new URL(request.url, 'http://localhost').pathname
    const file = path === '/background.jpg' ? background : join(dist, path === '/' ? 'index.html' : path)
    if (file !== background && !resolve(file).startsWith(dist + '/')) throw new Error('Invalid path')
    response.setHeader('Content-Type', mime[extname(file)] || 'application/octet-stream')
    response.end(await readFile(file))
  } catch {
    response.writeHead(404).end()
  }
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
let browser
try {
  browser = await chromium.launch()
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1 })
  const url = `http://127.0.0.1:${server.address().port}/?home=${encodeURIComponent(home)}&away=${encodeURIComponent(away)}&image=background.jpg`
  await page.goto(url)
  await page.locator('.thumbnail__background').evaluate(image => image.decode())
  await page.screenshot({ path: destination, type: 'jpeg', quality: 90 })
} finally {
  await browser?.close()
  server.close()
}
