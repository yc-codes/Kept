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
