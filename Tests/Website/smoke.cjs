const assert = require('node:assert/strict');
const { test } = require('node:test');
const { resolve } = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require('playwright');

const url = pathToFileURL(resolve(__dirname, '../../website/index.html')).href;
const filterCounts = { all: 6, image: 3, link: 1, text: 2, favorites: 1 };

async function withBrowser(run) {
  const browser = await chromium.launch({ executablePath: process.env.KEPT_TEST_CHROME });
  try {
    await run(browser);
  } finally {
    await browser.close();
  }
}

test('website demo, all filters, keyboard detail, theme persistence and responsive layout', async () => {
  await withBrowser(async browser => {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    // The agent demo runs on timers, so a controllable clock can play it through without the wait.
    await page.clock.install();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(url);
    const cards = page.locator('#results .capture');
    const search = page.locator('#search');
    const filter = key => page.locator(`[data-filter="${key}"]`);
    for (const [key, count] of Object.entries(filterCounts)) {
      await filter(key).click();
      assert.equal(await cards.count(), count, key);
      assert.equal(await filter(key).getAttribute('aria-pressed'), 'true');
      assert.equal(await page.locator('[data-filter][aria-pressed=true]').count(), 1);
    }

    await search.fill('light ridge');
    assert.equal(await cards.count(), 1);
    const alpine = cards.first();
    assert.equal(await alpine.locator('strong').textContent(), 'Alpine morning');
    await alpine.press('Enter');
    const dialog = page.getByRole('dialog');
    await dialog.waitFor();
    assert.equal(await dialog.getByRole('heading').textContent(), 'Alpine morning');
    assert.match(await dialog.textContent(), /Favorite.*Note/s);
    await page.keyboard.press('Escape');
    await dialog.waitFor({ state: 'hidden' });
    assert.equal(await alpine.evaluate(element => element === document.activeElement), true);

    await filter('link').click();
    assert.equal(await cards.count(), 0);
    assert.match(await page.locator('#result-count').textContent(), /No matching captures/);
    await search.fill('FIELD moodboard');
    assert.equal(await cards.count(), 1);
    await cards.first().click();
    assert.match(await dialog.textContent(), /https:\/\/example\.com\/field-notes/);
    await dialog.getByRole('button', { name: 'Close capture' }).click();
    await dialog.waitFor({ state: 'hidden' });

    // Agents: the demo plays to its finished frame, and each agent has its own terminal command.
    const demo = page.locator('.agent-demo');
    await demo.scrollIntoViewIfNeeded();
    await page.locator('.agent-demo.playing').waitFor();
    assert.equal(await demo.locator('.demo-shots li.fixed').count(), 0, 'the demo starts over when it plays');
    await page.clock.runFor(15000);
    await page.locator('.agent-demo:not(.playing)').waitFor();
    assert.equal(await demo.locator('.demo-typed').textContent(), 'Kept fix last 4');
    assert.equal(await demo.locator('.demo-shots li.fixed').count(), 4);
    assert.equal(await demo.locator('.waiting').count(), 0);
    await demo.getByRole('button', { name: /replay/i }).click();
    assert.equal(await demo.locator('.demo-typed').textContent(), '');

    const command = page.locator('.install-codes code.on');
    const server = '"$HOME/Library/Application Support/Kept/kept-mcp"';
    assert.equal(await command.textContent(), `claude mcp add --scope user kept -- ${server}`);
    await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
    for (const [agent, expected] of [['Codex', `codex mcp add kept -- ${server}`], ['Other', '~/Library/Application Support/Kept/kept-mcp']]) {
      await page.getByRole('button', { name: agent, exact: true }).click();
      assert.equal(await page.locator('.install-codes code.on').count(), 1);
      assert.equal(await command.textContent(), expected);
      assert.equal(await page.locator('[data-agent][aria-pressed=true]').count(), 1);
      await page.getByRole('button', { name: 'Copy', exact: true }).click();
      await page.getByText(/Copied to your clipboard|Press ⌘C to copy/).waitFor();
      const copied = await page.evaluate(() => navigator.clipboard.readText().catch(() => getSelection().toString()));
      assert.equal(copied, expected);
    }

    const theme = page.getByRole('button', { name: 'Switch to light theme' });
    await theme.click();
    assert.equal(await page.locator('html').getAttribute('data-theme'), 'light');
    assert.match(await page.locator('#library-shot').getAttribute('src'), /library-light\.webp/);
    await page.reload();
    assert.equal(await page.locator('html').getAttribute('data-theme'), 'light');
    await page.getByRole('button', { name: 'Switch to dark theme' }).click();
    assert.equal(await page.locator('html').getAttribute('data-theme'), 'dark');
    for (const width of [1440, 768, 375]) {
      await page.setViewportSize({ width, height: 900 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), width, `layout at ${width}px`);
    }
    const localLinks = await page.locator('a[href^="#"]').evaluateAll(links =>
      links.filter(link => !document.getElementById(link.hash.slice(1))).map(link => link.hash));
    assert.deepEqual(localLinks, []);
    assert.deepEqual(errors, []);

    const restricted = await browser.newPage();
    await restricted.addInitScript(() => {
      Object.defineProperty(window, 'localStorage', { get() { throw new Error('Storage unavailable'); } });
    });
    await restricted.goto(url);
    await restricted.getByRole('button', { name: 'Switch to light theme' }).click();
    assert.equal(await restricted.locator('html').getAttribute('data-theme'), 'light');
  });
});

test('seeded browser monkey test exercises 800 randomized demo actions', async () => {
  await withBrowser(async browser => {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(url);
    const seeds = process.env.KEPT_TEST_SEED === undefined ? [1, 42, 90210, 0xFFFFFFFF] : [Number(process.env.KEPT_TEST_SEED)];
    assert.ok(seeds.every(seed => Number.isInteger(seed) && seed >= 0 && seed <= 0xFFFFFFFF));
    for (const seed of seeds) {
      await page.evaluate(({ seed, filterCounts }) => {
        let state = seed >>> 0;
        const roll = n => {
          state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
          return (state >>> 16) % n;
        };
        const filters = [...document.querySelectorAll('[data-filter]')];
        const search = document.querySelector('#search');
        const dialog = document.querySelector('#item-dialog');
        const theme = document.querySelector('button.theme');
        const results = document.querySelector('#results');
        const strings = ['', ' ', 'Studio', 'warmer COLORS', 'ridge', 'friday', '😀', '山', '<div>', '\0', 'x'.repeat(1000)];
        for (let step = 0; step < 200; step++) {
          const verify = (condition, message) => {
            if (!condition) throw new Error(`seed ${seed}, step ${step}: ${message}`);
          };
          if (dialog.open) dialog.querySelector('button').click();
          switch (roll(4)) {
            case 0:
              filters[roll(filters.length)].click();
              break;
            case 1:
              search.value = strings[roll(strings.length)];
              search.dispatchEvent(new Event('input', { bubbles: true }));
              break;
            case 2:
              theme.click();
              break;
            default: {
              const cards = [...results.children];
              if (cards.length) {
                const card = cards[roll(cards.length)];
                card.click();
                verify(dialog.open && dialog.querySelector('h2').textContent === card.querySelector('strong').textContent,
                       'detail matches clicked item');
              }
            }
          }
          const pressed = filters.filter(filter => filter.getAttribute('aria-pressed') === 'true');
          verify(pressed.length === 1, 'one active filter');
          const count = results.children.length;
          const maximum = filterCounts[pressed[0].dataset.filter];
          verify(count <= maximum && (search.value.trim() || count === maximum), 'filter count');
          verify(/^(light|dark)$/.test(document.documentElement.dataset.theme), 'valid theme');
        }
      }, { seed, filterCounts });
    }
    assert.deepEqual(errors, []);
  });
});
