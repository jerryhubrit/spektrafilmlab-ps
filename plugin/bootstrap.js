/* Keep startup failures visible even if the application module cannot load. */
console.log('[FilmLab] bootstrap loaded');
let started = false;
function startFilmLab() {
  if (started) return;
  const output = document.getElementById('status');
  if (!output) return;
  started = true;
  output.textContent = '正在初始化 FilmLab…';
  try {
    const manifest = require('./manifest.json');
    console.log('[FilmLab] loaded version', manifest.version, JSON.stringify(manifest.requiredPermissions));
    require('./main.js');
    console.log('[FilmLab] controls initialized');
  } catch (error) {
    output.textContent = '初始化失败：' + (error.message || String(error));
    console.error('[FilmLab] startup', error.stack || error);
  }
}
document.addEventListener('DOMContentLoaded', startFilmLab);
startFilmLab();
