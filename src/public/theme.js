// Runs before the page paints, so there is no flash of the wrong theme.
try {
  const saved = localStorage.getItem('theme');
  const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  document.documentElement.dataset.theme = saved === 'light' || saved === 'dark' ? saved : dark ? 'dark' : 'light';
} catch {
  document.documentElement.dataset.theme = 'light';
}
