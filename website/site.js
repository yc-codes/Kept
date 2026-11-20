const root = document.documentElement;
const themeButton = document.querySelector('.theme');
const libraryShot = document.querySelector('#library-shot');
const themeColor = document.querySelector('meta[name="theme-color"]');

function applyTheme(theme) {
  const isLight = theme === 'light';
  root.dataset.theme = isLight ? 'light' : 'dark';
  libraryShot.src = `assets/library-${root.dataset.theme}.webp`;
  themeButton.firstElementChild.textContent = isLight ? '☾' : '☼';
  themeButton.setAttribute('aria-label', `Switch to ${isLight ? 'dark' : 'light'} theme`);
  themeColor.content = isLight ? '#f7f4ed' : '#151513';
}

try {
  applyTheme(localStorage.getItem('kept-theme'));
} catch {
  applyTheme('dark');
}

themeButton.addEventListener('click', () => {
  applyTheme(root.dataset.theme === 'light' ? 'dark' : 'light');
  try {
    localStorage.setItem('kept-theme', root.dataset.theme);
  } catch {
    // Theme switching also works when browser storage is unavailable.
  }
});

const captures = [
  { title: 'Coastal walk', kind: 'image', image: 'coast.webp', alt: 'Gentle waves on the beach at sunset', method: 'Imported' },
  { title: 'Desert studies', kind: 'image', image: 'desert.webp', alt: 'Red sandstone formations beneath blue sky', method: 'Imported' },
  { title: 'Alpine morning', kind: 'image', image: 'alpine.webp', alt: 'Alpine peaks and a cabin beside a lake', method: 'Region snip', note: 'Look at the light across the ridge.', favorite: true },
  { title: 'Designing for attention', kind: 'link', text: 'https://example.com/field-notes', method: 'Copied', note: 'Reference for the next moodboard.' },
  { title: 'Studio notes', kind: 'text', text: 'Try warmer colors, tactile textures, and more room for the type.', method: 'Copied', note: 'For Friday’s review.' },
  { title: 'Type pairings', kind: 'text', text: 'A bold grotesk with a quiet editorial italic.', method: 'Saved manually' },
];

const search = document.querySelector('#search');
const filters = [...document.querySelectorAll('[data-filter]')];
const count = document.querySelector('#result-count');
const results = document.querySelector('#results');
const template = document.querySelector('#capture-template');
const dialog = document.querySelector('#item-dialog');
const detail = document.querySelector('#item-detail');
let activeFilter = 'all';

function captureImage(capture, alt) {
  const image = document.createElement('img');
  image.src = `assets/${capture.image}`;
  image.alt = alt;
  return image;
}

function showCapture(capture) {
  const title = document.createElement('h2');
  title.id = 'item-title';
  title.textContent = capture.title;

  const info = document.createElement('p');
  info.className = 'capture-kind';
  info.textContent = capture.favorite ? `${capture.method} · Favorite` : capture.method;
  detail.replaceChildren(title, info);

  const content = capture.image ? captureImage(capture, capture.alt) : document.createElement('p');
  if (!capture.image) content.textContent = capture.text;
  detail.append(content);

  if (capture.note) {
    const note = document.createElement('p');
    note.textContent = `Note — ${capture.note}`;
    detail.append(note);
  }
  dialog.showModal();
}

function render() {
  const words = search.value.toLowerCase().trim().split(/\s+/).filter(Boolean);
  const matches = captures.filter(capture => {
    const matchesFilter = activeFilter === 'favorites'
      ? capture.favorite
      : activeFilter === 'all' || activeFilter === capture.kind;
    const searchable = [capture.title, capture.text, capture.note].join(' ').toLowerCase();
    return matchesFilter && words.every(word => searchable.includes(word));
  });

  count.textContent = matches.length
    ? `${matches.length} ${matches.length === 1 ? 'item' : 'items'}`
    : 'No matching captures. Try another search or filter.';

  results.replaceChildren(...matches.map(capture => {
    const card = template.content.firstElementChild.cloneNode(true);
    const preview = card.querySelector('.capture-preview');
    if (capture.image) {
      const image = captureImage(capture, '');
      image.loading = 'lazy';
      preview.append(image);
    } else {
      preview.textContent = capture.text;
    }
    preview.setAttribute('aria-hidden', 'true');
    card.querySelector('.capture-kind').textContent = capture.method;
    card.querySelector('strong').textContent = capture.title;
    card.addEventListener('click', () => showCapture(capture));
    return card;
  }));
}

search.addEventListener('input', render);
filters.forEach(button => button.addEventListener('click', () => {
  activeFilter = button.dataset.filter;
  filters.forEach(filter => filter.setAttribute('aria-pressed', String(filter === button)));
  render();
}));

render();

// Agents: the "Kept fix last 4" demo. The page ships its finished frame; this plays the story once when
// the demo scrolls into view, and again on Replay.
const agentDemo = document.querySelector('.agent-demo');
const typed = agentDemo.querySelector('.demo-typed');
const request = typed.textContent;
const call = agentDemo.querySelector('.demo-call');
const shots = [...agentDemo.querySelectorAll('.demo-shots li')];
const done = agentDemo.querySelector('.demo-done');
const replay = agentDemo.querySelector('.demo-replay');
let demoTimer;

function playDemo() {
  clearTimeout(demoTimer);
  agentDemo.classList.add('playing');
  typed.textContent = '';
  [call, done, ...shots].forEach(element => element.classList.add('waiting'));
  shots.forEach(shot => shot.classList.remove('fixed'));

  // Each step waits its delay after the one before it.
  const steps = [];
  for (let length = 1; length <= request.length; length++) {
    steps.push([length === 1 ? 600 : 70, () => { typed.textContent = request.slice(0, length); }]);
  }
  steps.push([450, () => call.classList.remove('waiting')]);
  shots.forEach((shot, index) => steps.push([index ? 160 : 500, () => shot.classList.remove('waiting')]));
  shots.forEach((shot, index) => steps.push([index ? 750 : 900, () => shot.classList.add('fixed')]));
  steps.push([500, () => {
    done.classList.remove('waiting');
    agentDemo.classList.remove('playing');
  }]);

  (function next() {
    const step = steps.shift();
    if (!step) return;
    demoTimer = setTimeout(() => {
      step[1]();
      next();
    }, step[0]);
  })();
}

if (!matchMedia('(prefers-reduced-motion: reduce)').matches && 'IntersectionObserver' in window) {
  replay.hidden = false;
  replay.addEventListener('click', playDemo);
  const seen = new IntersectionObserver(entries => {
    if (entries.some(entry => entry.isIntersecting)) {
      seen.disconnect();
      playDemo();
    }
  }, { threshold: 0.6 });
  seen.observe(agentDemo);
}

// Agents: the terminal command for each agent. Kept keeps its server at the same path on every Mac.
const installTabs = [...document.querySelectorAll('[data-agent]')];
const installCodes = [...document.querySelectorAll('[data-command]')];
const installCopy = document.querySelector('#install-copy');
const installNote = document.querySelector('#install-note');
let noteTimer;

function shownInstall() {
  return installCodes.find(code => code.classList.contains('on'));
}

installTabs.forEach(tab => tab.addEventListener('click', () => {
  clearTimeout(noteTimer);
  installTabs.forEach(other => other.setAttribute('aria-pressed', String(other === tab)));
  installCodes.forEach(code => code.classList.toggle('on', code.dataset.command === tab.dataset.agent));
  installNote.textContent = shownInstall().dataset.note;
}));

installCopy.addEventListener('click', async () => {
  const code = shownInstall();
  let copied = true;
  try {
    await navigator.clipboard.writeText(code.textContent);
  } catch {
    // No clipboard access: select the command so one keystroke copies it.
    copied = false;
    getSelection().selectAllChildren(code);
  }
  installNote.textContent = copied ? 'Copied to your clipboard.' : 'Selected. Press ⌘C to copy.';
  clearTimeout(noteTimer);
  noteTimer = setTimeout(() => { installNote.textContent = shownInstall().dataset.note; }, 2400);
});
