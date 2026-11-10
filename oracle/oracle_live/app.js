'use strict';
/* Raven Music — oracle live (Vue 3, глобальная сборка).
   Поведение портировано из tmp/Raven/examples/music/{main.c,tags.c,library.c}:
   симуляция плеера по часам, акцент и фон из цветов обложки, визуализатор
   с «битом» каждые полсекунды, уведомления в острове (2.5 с), shuffle/repeat,
   лайки, очередь, поиск, страница альбома/плейлиста, настройки.
   Верстка и данные 1:1 с оракулом raven_music (статическим). */

/* ------------------------------------------------------------------ utils */

function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }

/* library.c: тот же LCG (rand не нужен — детерминированно на альбом) */
function lcg(seed) {
  let s = seed >>> 0;
  return () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s >>> 8; };
}

/* библиотека.c: пулы имён треков (взгляды оригинала) */
const POOL_ADJ = ['Endless', 'Burning', 'Quiet', 'Electric', 'Velvet', 'Silver', 'Restless', 'Golden', 'Paper', 'Wild', 'Static', 'Crimson', 'Glass', 'Distant', 'Midnight', 'Faded', 'Lonely', 'Northern'];
const POOL_NOUN = ['Gardens', 'Waves', 'Streets', 'Summers', 'Machines', 'Lights', 'Ghosts', 'Rivers', 'Cathedrals', 'Embers', 'Highways', 'Horizons', 'Lanterns', 'Mirrors', 'Comets', 'Tides', 'Valleys', 'Arcades'];
const POOL_PLACE = ['Berlin', 'Seoul', 'July', 'Winter', 'the Desert', 'the Coast', 'Paris', 'Dawn', 'Midnight', 'the Valley', 'Nowhere', 'June'];
const POOL_VERB = ['Leave', 'Hold', 'Carry', 'Follow', 'Break', 'Keep', 'Lose', 'Find'];
const POOL_ADV = ['Tonight', 'Alone', 'Forever', 'Slowly', 'Again', 'Together', 'Home', 'Away'];

/* тёмная тема: цвет * k (как background_effect / hero в main.c) */
function scaleHex(hex, k) {
  const n = parseInt(hex.slice(1), 16);
  const r = Math.round(((n >> 16) & 255) * k), g = Math.round(((n >> 8) & 255) * k), b = Math.round((n & 255) * k);
  return '#' + ((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1);
}
function mix(hex, k) { /* осветление к белому, для плашек */
  const n = parseInt(hex.slice(1), 16);
  const f = c => Math.round(c + (255 - c) * k);
  return '#' + ((1 << 24) + (f((n >> 16) & 255) << 16) + (f((n >> 8) & 255) << 8) + f(n & 255)).toString(16).slice(1);
}

function fmtTime(sec) {
  sec = Math.max(0, Math.floor(sec));
  const m = Math.floor(sec / 60), s = sec % 60;
  return m + ':' + (s < 10 ? '0' : '') + s;
}

/* library.c: make_accent — цвет, который читается как акцент на тёмном окне
   (насыщенность 0.45..0.85, яркость 0.78..0.98) */
function makeAccent(hex) {
  const n = parseInt(hex.slice(1), 16);
  let r = ((n >> 16) & 255) / 255, g = ((n >> 8) & 255) / 255, b = (n & 255) / 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
  let h = 0, s = max > 0 ? d / max : 0, v = max;
  if (d > 0) {
    if (max === r) h = (((g - b) / d + 6) % 6) / 6;
    else if (max === g) h = ((b - r) / d + 2) / 6;
    else h = ((r - g) / d + 4) / 6;
  }
  s = Math.min(Math.max(s, 0.45), 0.85);
  v = Math.min(Math.max(v, 0.78), 0.98);
  const out = [5, 3, 1].map(k => {
    const x = (k + h * 6) % 6;
    return v - v * s * Math.max(0, Math.min(Math.min(x, 4 - x), 1));
  });
  const to = c => ('0' + Math.round(c * 255).toString(16)).slice(-2);
  return '#' + to(out[0]) + to(out[1]) + to(out[2]);
}

/* ------------------------------------------------------------------ data */
/* Кураторский набор — те же альбомы, цвета и списки, что в статическом
   оракуле raven_music (снимок приложения). Треки не-Tides генерируются
   детерминированно, как в library.c. */

const ALBUMS = [
  { ini: 'DH', c1: '#E92236', c2: '#571DC6', title: 'Tides', artist: 'The Distant Horizon', year: 2026, genre: 'Rock' },
  { ini: 'CM', c1: '#237FEC', c2: '#C3C61D', title: 'Restless Satellites', artist: 'The Copper Motel', year: 2024, genre: 'Electronic' },
  { ini: 'NK', c1: '#98C61D', c2: '#C61D9F', title: 'Mirrors', artist: 'Noor Kane', year: 1998, genre: 'Pop' },
  { ini: 'RQ', c1: '#5EA6C6', c2: '#C6714A', title: 'The Paper Lanterns', artist: 'Remy Quinn', year: 2024, genre: 'Folk' },
  { ini: 'ES', c1: '#3AC69E', c2: '#61C626', title: 'Faded Summer', artist: 'The Endless Strangers', year: 1989, genre: 'Chill' },
  { ini: 'SK', c1: '#DC2091', c2: '#1DC661', title: 'Electric Highways', artist: 'Sasha Kane', year: 2022, genre: 'Soul' },
  { ini: 'OL', c1: '#C66F1D', c2: '#1D24C6', title: 'The Blue Comets', artist: 'Otis Lindqvist', year: 2010, genre: 'Jazz' },
  { ini: 'SC', c1: '#DC2091', c2: '#1D8AC6', title: 'Cathedral in Berlin', artist: 'The Static Comets', year: 2013, genre: 'Rock' },
  { ini: 'EW', c1: '#E82266', c2: '#2E1DC6', title: 'Endless Gardens', artist: 'The Electric Wolves', year: 2012, genre: 'Indie' },
  { ini: 'KD', c1: '#5EA6C6', c2: '#4AC667', title: 'The Stray Embers', artist: 'Kai Delacroix', year: 2026, genre: 'Chill' },
  { ini: 'HH', c1: '#E82266', c2: '#1DC68C', title: 'Heartbeat in July', artist: 'The Hollow Harbor', year: 2022, genre: 'R&B' },
  { ini: 'AK', c1: '#3B63C6', c2: '#27C68C', title: 'Glass Gardens', artist: 'Ava Kane', year: 2026, genre: 'Indie' },
  { ini: 'GH', c1: '#237FEC', c2: '#71C61D', title: 'Heartbeat in Seoul', artist: 'The Golden Horizon', year: 2024, genre: 'Pop' },
  { ini: 'KA', c1: '#E82266', c2: '#1D5EC6', title: 'Crimson Ghosts', artist: 'Kai Ash', year: 2025, genre: 'Hip-Hop' },
];

/* Tides: 11 треков оригинала (коллекция статического оракула) */
const TIDES = [
  ['Glass Waves', 300, 0], ['Midnight Horizon', 302, 0], ['Static Cathedral', 254, 1],
  ['Leave Me Tonight', 192, 0], ['Burning Weather', 191, 0], ['The Arcade', 172, 0],
  ['the Desert, Forever', 193, 1], ['Daydreams', 258, 0], ['The Machines', 323, 0],
  ['the Valley, Home', 221, 0], ['Seoul, Tonight', 203, 0],
];

const PLAYLISTS = [
  { title: 'Liked songs', cover: -1, description: 'Every song you keep close.' },
  { title: 'Late night drive', cover: 8, description: 'Long roads, city lights and the windows down.' },
  { title: 'Focus flow', cover: 2, description: 'Soft, steady, out of the way.' },
  { title: 'Sunday morning', cover: 5, description: 'Slow starts and a second coffee.' },
  { title: 'Heavy rotation', cover: 5, description: 'What the week played the most.' },
  { title: 'Fresh finds', cover: 1, description: 'New songs, straight from the wire.' },
];

/* жанровые плитки Search: цвет — g_genre_colors из library.c */
const GENRES = [
  { name: 'Pop', color: '#E8115B', ini: 'DH', c1: '#E92236', c2: '#571DC6' },
  { name: 'Hip-Hop', color: '#BA5D07', ini: 'CM', c1: '#237FEC', c2: '#C3C61D' },
  { name: 'Rock', color: '#E91429', ini: 'CW', c1: '#3AC69E', c2: '#C64526' },
  { name: 'Indie', color: '#608108', ini: 'ES', c1: '#3AC69E', c2: '#61C626' },
  { name: 'R&B', color: '#8D67AB', ini: 'RQ', c1: '#98C61D', c2: '#9D1DC6' },
  { name: 'Electronic', color: '#0D73EC', ini: 'CM', c1: '#237FEC', c2: '#C3C61D' },
  { name: 'Soul', color: '#DC148C', ini: 'SK', c1: '#DC2091', c2: '#1DC661' },
  { name: 'Folk', color: '#477D95', ini: 'OL', c1: '#C66F1D', c2: '#1D24C6' },
  { name: 'Jazz', color: '#1E3264', ini: 'BH', c1: '#5EA6C6', c2: '#4AC667' },
  { name: 'Chill', color: '#27856A', ini: 'KD', c1: '#5EA6C6', c2: '#4AC667' },
];

const LOOKS = ['Nocturne', 'Aurora', 'Daylight', 'Windows Light', 'Windows Dark', 'macOS Light', 'macOS Dark',
  'GNOME Light', 'GNOME Dark', 'KDE Light', 'KDE Dark', 'Glass', 'High Contrast', 'Print', 'Sepia', 'Midnight'];
const EFFECTS = ['Mesh', 'Aurora', 'Plasma', 'Spotlight', 'Shimmer', 'None'];

/* --- сборка библиотеки --- */
const TRACKS = [];   /* { album, title, seconds, liked, plays } */
for (let a = 0; a < ALBUMS.length; a++) {
  const album = ALBUMS[a];
  album.tracks = [];
  if (a === 0) {
    for (const [title, sec, liked] of TIDES)
      album.tracks.push(TRACKS.push({ album: a, title, seconds: sec, liked: !!liked, plays: 0 }) - 1);
  } else {
    const rnd = lcg(20261101 + a * 7919);
    const pick = n => rnd() % n;
    const count = 6 + pick(7);
    for (let t = 0; t < count; t++) {
      const mode = pick(6);
      let title;
      if (mode === 0) title = POOL_ADJ[pick(POOL_ADJ.length)] + ' ' + POOL_NOUN[pick(POOL_NOUN.length)];
      else if (mode === 1) title = POOL_NOUN[pick(POOL_NOUN.length)] + ' of ' + POOL_PLACE[pick(POOL_PLACE.length)];
      else if (mode === 2) title = POOL_VERB[pick(POOL_VERB.length)] + ' Me ' + POOL_PLACE[pick(POOL_PLACE.length)];
      else if (mode === 3) title = POOL_VERB[pick(POOL_VERB.length)] + ' Me ' + POOL_ADV[pick(POOL_ADV.length)];
      else if (mode === 4) title = POOL_PLACE[pick(POOL_PLACE.length)] + ', ' + POOL_ADV[pick(POOL_ADV.length)];
      else title = POOL_ADJ[pick(POOL_ADJ.length)] + ' ' + POOL_PLACE[pick(POOL_PLACE.length)];
      album.tracks.push(TRACKS.push({ album: a, title, seconds: 128 + pick(200), liked: pick(6) === 0, plays: 0 }) - 1);
    }
  }
}

/* треки плейлистов (детерминированно; 0-й — Liked songs, живой) */
function fillPlaylist(p) {
  if (p === 0) return TRACKS.map((t, i) => i).filter(i => TRACKS[i].liked);
  const rnd = lcg(20261101 + p * 977), pick = n => rnd() % n;
  const count = 14 + p * 3, out = [];
  for (let i = 0; i < count; i++) out.push(pick(TRACKS.length));
  return out;
}
for (let p = 0; p < PLAYLISTS.length; p++) PLAYLISTS[p].trackList = fillPlaylist(p);

/* ------------------------------------------- tags.c: fake_level визуализатора */
function fakeLevel(bar, bars, time) {
  const x = bar / (bars > 1 ? bars - 1 : 1);
  const beat = Math.pow(0.5 + 0.5 * Math.cos((time % 0.5) * 12.566), 6);
  const bass = (1 - x) * (0.55 + 0.45 * beat);
  const body = 0.5 + 0.25 * Math.sin(time * (3.1 + bar * 0.37) + bar * 1.7) + 0.2 * Math.sin(time * (7.3 + bar * 0.11) + bar);
  return clamp(0.15 + bass * 0.6 + body * (0.35 + x * 0.25) * (1 - x * 0.35), 0.05, 1);
}

/* общее живое состояние для <ra-vis> (модульный reactive, вне рендера корня) */
const LIVE = Vue.reactive({ playing: true });

/* ------------------------------------------------------- компонент Visualizer */
const RaVis = {
  props: { bars: { type: Number, default: 5 }, h: { type: Number, default: 14 }, min: { type: Number, default: 3 } },
  template: '<div class="vis" aria-hidden="true"><i v-for="n in bars" :key="n"></i></div>',
  mounted() { this.levels = new Array(this.bars).fill(0.08); this.last = 0; this.raf = requestAnimationFrame(this.step); },
  beforeUnmount() { cancelAnimationFrame(this.raf); },
  methods: {
    step(nowMs) {
      const now = nowMs / 1000, dt = this.last > 0 ? Math.min(now - this.last, 0.05) : 0.016;
      this.last = now;
      const kids = this.$el.children;
      for (let i = 0; i < this.bars; i++) {
        const playing = LIVE.playing;
        const target = playing ? fakeLevel(i, this.bars, now) : 0.08;
        const speed = target > this.levels[i] ? 22 : (playing ? 9 : 4); /* attack/release как в tags.c */
        this.levels[i] += (target - this.levels[i]) * clamp(dt * speed, 0, 1);
        const bar = kids[i];
        if (bar) {
          bar.style.height = Math.max(this.levels[i] * this.h, this.min) + 'px';
          bar.style.opacity = (0.55 + 0.45 * this.levels[i]).toFixed(3);
        }
      }
      this.raf = requestAnimationFrame(this.step);
    },
  },
};

/* ---------------------------------------------------------- компонент Slider */
const RaSlider = {
  props: { value: { type: Number, default: 0 } },
  emits: ['set'],
  template: '<div class="slider"><div class="track" ref="tr" @pointerdown="down" @pointermove="move" @pointerup="up" @pointercancel="up">'
    + '<div class="fill" :style="{ width: (v * 100) + \'%\' }"></div>'
    + '<div class="knob" :style="{ left: \'calc(\' + (v * 100) + \'% - 6px)\' }"></div>'
    + '</div></div>',
  computed: { v() { return clamp(this.value, 0, 1); } },
  methods: {
    frac(e) {
      const r = this.$refs.tr.getBoundingClientRect();
      return clamp((e.clientX - r.left) / r.width, 0, 1);
    },
    down(e) { e.preventDefault(); this.$refs.tr.setPointerCapture(e.pointerId); this.drag = true; this.$emit('set', this.frac(e)); },
    move(e) { if (this.drag) this.$emit('set', this.frac(e)); },
    up() { this.drag = false; },
  },
};

/* ------------------------------------------------------------------- root */
const app = Vue.createApp({
  components: { RaVis, RaSlider },

  data() {
    return {
      albums: ALBUMS, tracks: TRACKS, playlists: PLAYLISTS, genres: GENRES, looks: LOOKS, effects: EFFECTS,

      /* страница и навигация (history как в main.c) */
      page: 'home', history: [],
      colKind: 'album', colIndex: 0,
      libFilter: 0,
      query: '',

      /* плеер */
      track: ALBUMS[0].tracks[0], position: 84, playing: true,
      shuffle: false, repeat: 0 /* off/all/one */,
      volume: 0.7, muted: false,
      queue: ALBUMS[0].tracks.slice(), queuePos: 0, context: 'Tides',

      /* настройки (значения по умолчанию — из main()) */
      followCover: true, picked: '#B79CFF', effect: 0, animate: true, panel: true,
      crossfade: 5, look: 0, normalize: true, quality: 2,
      albumLikes: ALBUMS.map((_, i) => i === 2 || i === 5),

      notice: '', noticeTimer: 0,

      /*.home подборки — как в статическом оракуле */
      quickPicks: [3, 1, 2, 0, 4, 5],
      recentPicks: [6, 7, 8, 9, 10],
      artistPicks: [6, 5, 2, 9, 3],
    };
  },

  computed: {
    trackObj() { return this.tracks[this.track]; },
    album() { return this.trackObj ? this.albums[this.trackObj.album] : this.albums[0]; },

    /* акцент следует обложке (update_accent + make_accent в main.c/library.c) */
    accent() { return this.followCover ? makeAccent(this.album.c1) : this.picked; },
    winStyle() { return { '--accent': this.accent }; },
    meshStyle() {
      const a = this.album;
      return { '--m1': scaleHex(a.c1, 0.55), '--m2': scaleHex(a.c2, 0.35), '--m3': scaleHex(a.c1, 0.35) };
    },
    heroStyle() {
      const a = this.colKind === 'album' ? this.albums[this.colIndex] : this.albums[this.playlists[this.colIndex].cover < 0 ? 0 : this.playlists[this.colIndex].cover];
      return {
        background: 'radial-gradient(1200px 500px at 75% -10%, ' + scaleHex(a.c1, 0.55) + ', transparent 70%),'
          + ' radial-gradient(900px 500px at 15% 120%, ' + scaleHex(a.c2, 0.22) + ', transparent 70%), #111117',
      };
    },
    npArtistStyle() {
      const a = this.album;
      return { background: 'radial-gradient(400px 200px at 80% 0%, ' + scaleHex(a.c1, 0.7) + ', #111117 85%)' };
    },

    elapsed() { return fmtTime(this.position); },
    length() { return this.trackObj ? fmtTime(this.trackObj.seconds) : '0:00'; },
    seekFrac() { return this.trackObj ? clamp(this.position / this.trackObj.seconds, 0, 1) : 0; },

    islandText() { return this.notice || (this.trackObj ? this.trackObj.title : ''); },
    greeting() {
      const h = new Date().getHours();
      if (h < 5) return 'Good night';
      if (h < 12) return 'Good morning';
      if (h < 18) return 'Good afternoon';
      return 'Good evening';
    },

    likedTracks() { return this.tracks.map((t, i) => i).filter(i => this.tracks[i].liked); },
    likedCount() { return this.likedTracks.length; },

    /* сайдбар: фильтры как в fill_sidebar() */
    sidebarRows() {
      const rows = [];
      if (this.libFilter !== 2) for (let p = 0; p < this.playlists.length; p++) {
        const pl = this.playlists[p], n = p === 0 ? this.likedCount : pl.trackList.length;
        rows.push({ round: true, ini: p === 0 ? '♥' : this.albums[pl.cover].ini, c1: p === 0 ? '#B79CFF' : this.albums[pl.cover].c1, c2: p === 0 ? '#6D28D9' : this.albums[pl.cover].c2, t: pl.title, s: 'Playlist · ' + n + ' songs', open: () => this.openPlaylist(p) });
      }
      if (this.libFilter !== 1) for (const a of this.albums)
        rows.push({ round: false, ini: a.ini, c1: a.c1, c2: a.c2, t: a.title, s: 'Album · ' + a.artist, open: () => this.openAlbum(this.albums.indexOf(a)) });
      return rows;
    },

    /* new releases: сортировка по году, как fill_home() */
    newReleases() {
      return this.albums.map((a, i) => i).sort((x, y) => this.albums[y].year - this.albums[x].year || x - y);
    },

    /* поиск: run_search() из main.c */
    searchAlbums() {
      const q = this.query.trim().toLowerCase();
      if (!q) return [];
      return this.albums.map((a, i) => i).filter(i => {
        const a = this.albums[i];
        return a.title.toLowerCase().includes(q) || a.artist.toLowerCase().includes(q) || a.genre.toLowerCase().includes(q);
      });
    },
    searchSongs() {
      const q = this.query.trim().toLowerCase();
      if (!q) return [];
      const out = [];
      for (let i = 0; i < this.tracks.length && out.length < 5; i++) {
        const t = this.tracks[i];
        if (t.title.toLowerCase().includes(q) || this.albums[t.album].artist.toLowerCase().includes(q)) out.push(i);
      }
      return out;
    },
    searchTop() {
      if (this.searchAlbums.length) return this.searchAlbums[0];
      if (this.searchSongs.length) return this.tracks[this.searchSongs[0]].album;
      return -1;
    },

    /* коллекция */
    colAlbum() {
      if (this.colKind === 'album') return this.albums[this.colIndex];
      const pl = this.playlists[this.colIndex], cover = pl.cover < 0 ? this.albums[0] : this.albums[pl.cover];
      return cover;
    },
    colTracks() {
      if (this.colKind === 'album') return this.albums[this.colIndex].tracks;
      const pl = this.playlists[this.colIndex];
      return pl.trackList.slice();
    },
    colIsLiked() {
      return this.colKind === 'playlist' ? false : !!this.albumLikes[this.colIndex];
    },
    colMeta() {
      const list = this.colTracks, total = list.reduce((s, i) => s + this.tracks[i].seconds, 0);
      if (this.colKind === 'album')
        return '· ' + this.albums[this.colIndex].year + ' · ' + list.length + ' songs, ' + Math.floor(total / 60) + ' min ' + (total % 60) + ' s';
      const h = Math.floor(total / 3600), m = Math.round(total % 3600 / 60);
      return '· ' + list.length + ' songs, about ' + (h > 0 ? h + ' h ' + m + ' min' : m + ' min');
    },
    colPlayIcon() {
      /* pause только когда играет именно этот список (collection.play в main.c) */
      const same = this.queue.length === this.colTracks.length && this.queue.every((t, i) => t === this.colTracks[i]) && !this.shuffle;
      return same && this.playing ? '#i-pause' : '#i-play';
    },
    colArtist() { return this.colKind === 'album' ? this.albums[this.colIndex].artist : 'Raven Music'; },

    /* очередь в панели now playing */
    queueNext() { return this.queue.slice(this.queuePos + 1, this.queuePos + 5); },
    currentLiked() { return this.trackObj ? !!this.trackObj.liked : false; },
    volIcon() { return (this.muted || this.volume <= 0.001) ? '#i-muted' : '#i-volume'; },
    libSummary() {
      const saved = this.albumLikes.filter(Boolean).length;
      return this.playlists.length + ' playlists, ' + this.albums.length + ' albums (' + saved + ' saved), ' + this.likedCount + ' liked songs.';
    },
  },

  watch: {
    playing(v) { LIVE.playing = v; this.syncTitle(); },
    trackObj: { handler() { this.syncTitle(); }, immediate: true },
  },

  mounted() {
    LIVE.playing = this.playing;
    /* стартовое состояние из location.hash — аналог RAVEN_MUSIC_PAGE /
       RAVEN_MUSIC_PAUSED / RAVEN_MUSIC_ISLAND у main.c: #album, #playlist,
       #search, #genres, #library, #settings (+ «,paused», «,island») */
    const opts = location.hash.slice(1).split(',').map(s => s.trim());
    if (opts.includes('album')) this.openAlbum(0);
    else if (opts.includes('playlist')) this.openPlaylist(1);
    else if (opts.includes('search')) { this.query = 'the'; this.showPage('search', true); }
    else if (opts.includes('genres')) this.showPage('search', true);
    else if (opts.includes('library')) this.showPage('library', true);
    else if (opts.includes('settings')) this.showPage('settings', true);
    if (opts.includes('paused')) this.playing = false;
    if (opts.includes('island')) document.querySelector('.island') && document.querySelector('.island').classList.add('stay-open');
    if (opts.includes('dump')) this.$nextTick(() => this.dumpGeometry());

    window.addEventListener('keydown', this.onKey);
    this.last = performance.now() / 1000;
    const loop = nowMs => {
      const now = nowMs / 1000, dt = Math.min(now - this.last, 0.25);
      this.last = now;
      if (this.playing && this.track >= 0) {
        this.position += dt;
        const len = this.tracks[this.track].seconds;
        if (this.position >= len) this.onEnded();
      }
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  },

  methods: {
    /* ------------------------------------------------------------ helpers */
    fmt: fmtTime,
    cov(a) { return { '--c1': a.c1, '--c2': a.c2 }; },
    covCur() { return this.cov(this.album); },           /* Cover Album="current" */
    covG(g) { return { '--c1': g.c1, '--c2': g.c2 }; },
    syncTitle() { document.title = this.trackObj ? this.trackObj.title + ' · ' + this.album.artist : 'Raven Music'; },
    notify(text) {
      this.notice = text;
      clearTimeout(this.noticeTimer);
      this.noticeTimer = setTimeout(() => { this.notice = ''; }, 2500);
    },
    notInDemo() { this.notify('Not in this demo'); },

    /* -------------------------------------------------------- навигация */
    showPage(p, remember) {
      if (this.page !== p) {
        if (remember) { this.history.push(this.page); if (this.history.length > 64) this.history.shift(); }
        this.page = p;
      }
      if (p === 'library' || p === 'collection') this.page = p;
    },
    navTo(p) { this.showPage(p, true); },
    back() { if (this.history.length) this.page = this.history.pop(); },
    openAlbum(i) {
      this.colKind = 'album'; this.colIndex = i;
      this.showPage('collection', true);
      if (this.albumLikes[i]) this.notify('It is your playlist already');
    },
    openPlaylist(p) {
      if (p === 0) this.playlists[0].trackList = this.likedTracks.slice();
      this.colKind = 'playlist'; this.colIndex = p;
      this.showPage('collection', true);
    },
    setFilter(i) { this.libFilter = i; },
    chipHome(name) { if (name !== 'All') this.notify('Only music here'); },
    genreOpen(g) { this.query = g.name; this.showPage('search', true); },
    onSearch() { if (this.page !== 'search' && this.query.trim()) this.showPage('search', true); },
    topOpen() { if (this.searchTop >= 0) this.openAlbum(this.searchTop); },
    focusSearch() { this.$refs.search && this.$refs.search.focus(); },

    /* ----------------------------------------------------------- плеер */
    playList(list, start, context) {
      let queue = list.slice(), pos = queue.indexOf(start);
      if (pos < 0) { queue.push(start); pos = queue.length - 1; }
      if (this.shuffle) {
        /* play_list из main.c: start в голову, остальное перемешано */
        const first = queue[pos];
        queue[pos] = queue[0]; queue[0] = first;
        for (let i = queue.length - 1; i > 1; i--) {
          const j = 1 + Math.floor(Math.random() * i);
          const s = queue[i]; queue[i] = queue[j]; queue[j] = s;
        }
        pos = 0;
      }
      this.queue = queue; this.queuePos = pos; this.context = context;
      this.playPosition(pos);
    },
    playPosition(pos) {
      pos = ((pos % this.queue.length) + this.queue.length) % this.queue.length;
      this.queuePos = pos;
      this.track = this.queue[pos];
      this.tracks[this.track].plays++;
      this.position = 0;
      this.playing = true;
    },
    toggle() {
      if (this.track < 0) {
        /* player.toggle при пустом плеере: играет первый альбом */
        this.openAlbum(0);
        this.playList(this.albums[0].tracks, this.albums[0].tracks[0], this.albums[0].title);
        return;
      }
      this.playing = !this.playing;
    },
    next() {
      if (this.queue.length) this.playPosition(this.queuePos + 1 < this.queue.length ? this.queuePos + 1 : 0);
    },
    prev() {
      if (this.position > 3 || this.queuePos === 0) { this.position = 0; return; }
      this.playPosition(this.queuePos - 1);
    },
    onEnded() {
      if (this.repeat === 2) { this.position = 0; return; }            /* repeat one */
      if (this.queuePos + 1 < this.queue.length) { this.playPosition(this.queuePos + 1); return; }
      if (this.repeat === 1) { this.playPosition(0); return; }         /* repeat all */
      this.playing = false; this.position = 0;                          /* стоп */
    },
    seek(frac) {
      if (!this.trackObj) return;
      this.position = frac * this.trackObj.seconds;
    },
    setVolume(frac) {
      this.volume = frac;
      if (frac > 0.001) this.muted = false;
    },
    toggleMute() {
      if (this.muted || this.volume <= 0.001) { this.muted = false; if (this.volume <= 0.001) this.volume = 0.5; this.notify('Unmuted'); }
      else { this.muted = true; this.notify('Muted'); }
    },
    toggleShuffle() {
      this.shuffle = !this.shuffle;
      this.notify(this.shuffle ? 'Shuffle on' : 'Shuffle off');
    },
    cycleRepeat() {
      this.repeat = (this.repeat + 1) % 3;
      this.notify(['Repeat off', 'Repeat all', 'Repeat this song'][this.repeat]);
    },
    repeatIcon() { return this.repeat === 2 ? '#i-repeat-one' : '#i-repeat'; },
    likeTrack(i) {
      const t = this.tracks[i];
      t.liked = !t.liked;
      if (this.playlists[0] && this.colKind === 'playlist' && this.colIndex === 0) this.playlists[0].trackList = this.likedTracks.slice();
      if (i === this.track) this.notify(t.liked ? 'Added to Liked songs' : 'Removed from Liked songs');
    },
    likeCurrent() { if (this.track >= 0) this.likeTrack(this.track); },
    likeCollection() {
      if (this.colKind === 'playlist') { this.notify('It is your playlist already'); return; }
      const v = !this.albumLikes[this.colIndex];
      this.albumLikes[this.colIndex] = v;
      this.notify(v ? 'Saved to your library' : 'Removed from your library');
    },
    colPlay() {
      const same = this.queue.length === this.colTracks.length && this.queue.every((t, i) => t === this.colTracks[i]) && !this.shuffle;
      if (same) { this.toggle(); return; }
      const ctx = this.colKind === 'album' ? this.albums[this.colIndex].title : this.playlists[this.colIndex].title;
      this.playList(this.colTracks, this.colTracks[0], ctx);
    },
    colShuffle() {
      const list = this.colTracks, i = list.length ? list[Math.floor(Math.random() * list.length)] : 0;
      const ctx = this.colKind === 'album' ? this.albums[this.colIndex].title : this.playlists[this.colIndex].title;
      const keep = this.shuffle; /* collection.shuffle: shuffle на этот запуск */
      this.shuffle = true;
      this.playList(list, i, ctx);
      this.shuffle = keep;
      this.notify('Shuffle on');
    },
    playTrackRow(i) {
      /* трек из открытой коллекции играет её списком, иначе — своим альбомом */
      if (this.colTracks.includes(i)) {
        const ctx = this.colKind === 'album' ? this.albums[this.colIndex].title : this.playlists[this.colIndex].title;
        this.playList(this.colTracks, i, ctx);
      } else {
        const ai = this.tracks[i].album;
        this.playList(this.albums[ai].tracks, i, this.albums[ai].title);
      }
    },
    jumpQueue(n) { this.playPosition(this.queuePos + 1 + n); },
    togglePanel() { this.panel = !this.panel; },

    /* ------------------------------------------------------- настройки */
    onLook() {
      if (this.look !== 0) { this.notify('Not in this demo'); this.look = 0; }
    },
    onAccent(e) {
      this.picked = e.target.value;
      this.followCover = false;
    },
    setCrossfade(frac) { this.crossfade = Math.round(frac * 12); },

    /* --------------------------------------------- отладка: геометрия (#dump) */
    dumpGeometry() {
      const sels = ['.win', '.header', '.logo', '.search-pill', '.avatar', '.main', '.sidebar',
        '.nav-box', '.lib-box', '.chips .chip', '.lib-row', '.lib-row .cover', '.center',
        '.home-chips .chip', '.greeting', '.quick', '.quick .cover', '.section-head .t',
        '.album-card', '.album-card .cover', '.nowplaying', '.np-inner', '.np-cover',
        '.np-title', '.np-artist-card', '.np-queue-card', '.np-q-row', '.np-vis',
        '.playerbar', '.pb-song .cover', '.play-round', '.pb-seek .slider', '.pb-right .slider',
        '.icon-btn', '.island', '.genre-tile', '.hero', '.hero .cover', '.col-heads',
        '.track-row', '.track-row .cover', '.settings-col', '.set-row', '.combo', '.switch'];
      const out = [];
      const win = document.querySelector('.win').getBoundingClientRect();
      for (const s of sels) {
        const els = document.querySelectorAll(s);
        for (let i = 0; i < Math.min(els.length, 3); i++) {
          const r = els[i].getBoundingClientRect();
          out.push([s, i, Math.round(r.left - win.left), Math.round(r.top - win.top),
            Math.round(r.width), Math.round(r.height)].join(' '));
        }
      }
      const pre = document.createElement('pre');
      pre.id = 'geo-dump';
      pre.textContent = out.join('\n');
      document.body.appendChild(pre);
    },

    /* ------------------------------------------------------ клавиши (как в player.xml/main.c) */
    onKey(e) {
      const tag = (e.target.tagName || '').toLowerCase();
      const typing = tag === 'input' || tag === 'select' || tag === 'textarea';
      if (typing && e.key === 'Escape') { e.target.blur(); return; }
      if (e.code === 'Space' && !typing) { e.preventDefault(); this.toggle(); }
      else if (e.ctrlKey && e.code === 'ArrowRight') { e.preventDefault(); this.next(); }
      else if (e.ctrlKey && e.code === 'ArrowLeft') { e.preventDefault(); this.prev(); }
      else if (e.ctrlKey && e.key.toLowerCase() === 'l') { e.preventDefault(); this.likeCurrent(); }
      else if (e.ctrlKey && e.key.toLowerCase() === 'f') { e.preventDefault(); this.focusSearch(); }
      else if (e.ctrlKey && e.key.toLowerCase() === 'p') { e.preventDefault(); this.showPage('settings', true); }
      else if (e.altKey && e.code === 'ArrowLeft') { e.preventDefault(); this.back(); }
    },
  },
});

app.config.compilerOptions.whitespace = 'condense';
const vm = app.mount('#app');
