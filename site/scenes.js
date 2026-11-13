// The demos: real apps on a Mac desktop, with SigmaFlow's overlays playing over them.
(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const wait = ms => new Promise(r => setTimeout(() => r(true), reduce ? Math.min(ms, 60) : ms));
  const PACE = 130; // SigmaFlow: one word every 130 ms

  const ICON = {
    finder: 'apps/finder.png', chrome: 'apps/chrome.png', slack: 'apps/slack.png', cursor: 'apps/cursor.svg',
    mail: 'apps/mail.png', notes: 'apps/notes.png', claude: 'apps/claude.png', sigmaflow: 'apps/sigmaflow.png',
    terminal: 'apps/terminal.png', meet: 'apps/meet.svg', gmail: 'apps/gmail.svg', slides: 'apps/slides.png',
    zoom: 'apps/zoom.svg', chatgpt: 'apps/chatgpt.svg', notion: 'apps/notion.png', linear: 'apps/linear.svg',
    figma: 'apps/figma.png', obsidian: 'apps/obsidian.png', vscode: 'apps/vscode.png', xcode: 'apps/xcode.png',
    messages: 'apps/messages.png', whatsapp: 'apps/whatsapp.svg', discord: 'apps/discord.svg', docs: 'apps/docs.png',
    sheets: 'apps/sheets.png', word: 'apps/word.png', safari: 'apps/safari.png', arc: 'apps/arc.png', dia: 'apps/dia.png',
    facetime: 'apps/facetime.png', calendar: 'apps/calendar.png', reminders: 'apps/reminders.png',
    textedit: 'apps/textedit.png', freeform: 'apps/freeform.png', journal: 'apps/journal.png'
  };

  /* ---------- the desktop: menu bar, Dock, scale ---------- */
  function dress(desk) {
    const mb = document.createElement('div'); mb.className = 'menubar';
    mb.innerHTML = '<span class="apple"></span><b class="mb-app"></b><span>File</span><span>Edit</span><span>View</span><span>Window</span><span>Help</span><span class="right"><span class="sfmark" title="SigmaFlow"></span><span>Thu 22 Oct 2:30 PM</span></span>';
    desk.prepend(mb);
    const dock = document.createElement('div'); dock.className = 'dock';
    dock.innerHTML = desk.dataset.dock.split(',').map(a => `<span data-a="${a}" style="background-image:url('${ICON[a]}')"></span>`).join('');
    desk.appendChild(dock);
    setApp(desk, desk.dataset.app, desk.dataset.on);
  }
  function setApp(desk, name, on) {
    $('.mb-app', desk).textContent = name;
    $$('.dock span', desk).forEach(s => s.classList.toggle('on', s.dataset.a === on || s.dataset.a === 'sigmaflow' || s.dataset.a === 'finder'));
  }
  function fit(box) {
    const desk = box.firstElementChild;
    const narrow = box.dataset.nw && box.clientWidth < 600;
    const W = +(narrow ? box.dataset.nw : box.dataset.w), H = +(narrow ? box.dataset.nh : box.dataset.h);
    desk.classList.toggle('narrow', !!narrow);
    desk.style.width = W + 'px'; desk.style.height = H + 'px';
    const s = box.clientWidth / W;
    desk.style.transform = `scale(${s})`; box.style.height = `${H * s}px`; desk._scale = s;
  }

  /* ---------- text ---------- */
  function words(text) {
    return text.split(/(\s+)/).map(t => {
      if (/^\s+$/.test(t)) return document.createTextNode(t);
      const s = document.createElement('span'); s.className = 'w'; s.textContent = t; return s;
    });
  }
  async function flow(el, text, pace, alive) {
    for (const p of words(text)) {
      if (!alive()) return false;
      el.appendChild(p);
      if (p.nodeType === 1) { void p.offsetWidth; p.classList.add('in'); if (!reduce) await new Promise(r => setTimeout(r, pace)); }
    }
    return alive();
  }
  function blank(field) {
    field.innerHTML = '<span class="caret"></span>' + (field.dataset.ph ? `<span class="ph">${field.dataset.ph}</span>` : '');
  }
  async function land(field, text, alive) {
    field.innerHTML = ''; const t = document.createElement('span'); field.append(t);
    const ok = await flow(t, text, 16, alive);
    field.insertAdjacentHTML('beforeend', '<span class="caret"></span>');
    return ok;
  }

  /* ---------- SigmaFlow's overlay ---------- */
  function hud(el) {
    const meter = $('.sf-meter', el);
    if (meter && !meter.children.length) for (let i = 0; i < 14; i++) meter.append(document.createElement('i'));
    const dots = meter ? [...meter.children] : [];
    let mt = 0, ct = 0, lvl = 6;
    return {
      el, text: $('.sf-text', el),
      show() {
        el.classList.add('on');
        const tm = $('.tm', el); let s = 0; if (tm) tm.textContent = '00:00';
        clearInterval(ct); ct = setInterval(() => { s++; if (tm) tm.textContent = `00:${String(s).padStart(2, '0')}`; }, 1000);
        clearInterval(mt); mt = setInterval(() => { lvl = Math.max(3, Math.min(13, lvl + (Math.random() - .45) * 5)); dots.forEach((d, k) => d.classList.toggle('lit', k < Math.round(lvl))); }, 90);
      },
      quiet() { clearInterval(mt); clearInterval(ct); dots.forEach(d => d.classList.remove('lit')); },
      hide() { this.quiet(); el.classList.remove('on'); }
    };
  }
  function pointTo(desk, ptr, el, dx = .5, dy = .5) {
    const d = desk.getBoundingClientRect(), r = el.getBoundingClientRect(), s = desk._scale || 1;
    ptr.style.left = ((r.left - d.left) + r.width * dx) / s + 'px';
    ptr.style.top = ((r.top - d.top) + r.height * dy) / s + 'px';
    ptr.classList.add('on');
  }

  /* ---------- scenes ---------- */
  const SCENES = {};

  // Claude Code in Terminal: dictate a request to the agent.
  SCENES.claudecode = async (d, alive) => {
    const h = hud($('.sf-hud', d)), key = $('.sf-key', d), inp = $('.cc-in', d), out = $('.cc-out', d), hist = $('.cc-hist', d);
    inp.innerHTML = '<span class="caret"></span>'; out.innerHTML = ''; hist.innerHTML = ''; h.text.innerHTML = '';
    if (!await wait(900) || !alive()) return;
    key.classList.add('down'); h.show(); await wait(400);
    if (!await flow(h.text, 'um, add rate limiting to the signup endpoint, uh, ten requests a minute per IP', PACE * 2.2, alive)) return h.hide();
    await wait(500); key.classList.remove('down'); h.hide(); await wait(320);
    if (!await land(inp, 'Add rate limiting to the signup endpoint, ten requests a minute per IP.', alive)) return;
    await wait(1300); if (!alive()) return;
    hist.textContent = '> Add rate limiting to the signup endpoint, ten requests a minute per IP.';
    inp.innerHTML = '<span class="caret"></span>';
    const steps = ['<span class="dot">⏺</span> I’ll add a limit of ten requests a minute per IP to the signup endpoint.', '<span class="dot">⏺</span> <span class="tool">Read</span>(src/api/signup.ts)\n  ⎿  Read 24 lines', '<span class="dot">⏺</span> <span class="tool">Update</span>(src/api/signup.ts)\n  ⎿  Added rateLimit({ window: 60, max: 10 })'];
    for (const st of steps) { await wait(900); if (!alive()) return; out.insertAdjacentHTML('beforeend', st + '\n\n'); }
    await wait(3500);
  };

  // Autowrite in Slack: say what you want, SigmaFlow reads the screen and writes the reply.
  SCENES.autowrite = async (d, alive) => {
    const el = $('.sf-hud', d), h = hud(el), key = $('.sf-key', d), field = $('[data-field]', d), spot = $('.spot', d), win = $('.win', d), ptr = $('.pointer', d);
    const icon = $('.sf-row use', el), tm = $('.tm', el), meter = $('.sf-meter', el), q = $('.q', el), wr = $('.sf-write', el), send = $('.send', d);
    blank(field); q.innerHTML = ''; wr.innerHTML = ''; q.classList.remove('dim'); icon.setAttribute('href', '#i-pen'); tm.style.display = meter.style.display = '';
    send.classList.remove('ready'); spot.classList.remove('on'); win.classList.remove('spot-lift');
    if (!await wait(700) || !alive()) return;
    pointTo(d, ptr, field, .3, .5); await wait(900); ptr.classList.remove('on');
    key.classList.add('down'); await wait(300);
    spot.classList.add('on'); win.classList.add('spot-lift'); h.show(); await wait(500);
    if (!await flow(q, 'tell maya forty seats is the team plan, SSO is included, quote by tomorrow', PACE * 2.2, alive)) return h.hide();
    await wait(500); key.classList.remove('down'); h.quiet();
    icon.setAttribute('href', '#i-circle-dash'); tm.style.display = meter.style.display = 'none'; q.classList.add('dim');
    await wait(600);
    if (!await flow(wr, 'Hi Maya, glad the demo landed. Forty seats puts you on our Team plan, and SSO is included. I’ll send the quote over by tomorrow.', 55, alive)) return h.hide();
    await wait(700); h.hide(); spot.classList.remove('on'); await wait(250);
    if (!await land(field, 'Hi Maya, glad the demo landed. Forty seats puts you on our Team plan, and SSO is included. I’ll send the quote over by tomorrow.', alive)) return;
    win.classList.remove('spot-lift'); send.classList.add('ready');
    await wait(4000);
  };

  // Names: fix a word once in Notes, SigmaFlow adds it to the dictionary.
  SCENES.learns = async (d, alive) => {
    const h = hud($('.sf-hud', d)), key = $('.sf-key', d), field = $('[data-field]', d), n = $('.sf-notice', d);
    const e = $('.e', n), btn = $('.sf-btn', n), line = $('.sf-line', n), bar = $('.sf-line i', n), pair = $('.pair', n);
    field.innerHTML = '<span class="caret"></span>'; h.text.innerHTML = ''; n.classList.remove('on');
    if (!await wait(800) || !alive()) return;
    key.classList.add('down'); h.show(); await wait(400);
    if (!await flow(h.text, 'deploy the preview to ver sell before the demo', PACE * 2.2, alive)) return h.hide();
    await wait(400); key.classList.remove('down'); h.hide(); await wait(320);
    if (!await land(field, 'Deploy the preview to Ver sell before the demo.', alive)) return;
    await wait(900); if (!alive()) return;
    field.innerHTML = 'Deploy the preview to <span class="fx">Ver sell</span> before the demo.';
    const fx = $('.fx', field); await wait(300); fx.classList.add('sel'); await wait(900); if (!alive()) return;
    fx.classList.remove('sel'); fx.textContent = ''; fx.insertAdjacentHTML('afterend', '<span class="caret"></span>');
    for (const ch of 'Vercel') { if (!alive()) return; fx.textContent += ch; await wait(120); }
    await wait(800); if (!alive()) return;
    e.textContent = 'ADDING TO DICTIONARY'; btn.textContent = 'Not now'; line.style.display = ''; pair.style.display = '';
    bar.style.transition = 'none'; bar.style.transform = 'scaleX(1)';
    n.classList.add('on'); void bar.offsetWidth; bar.style.transition = 'transform 3.5s linear'; bar.style.transform = 'scaleX(0)';
    await wait(3600); if (!alive()) return n.classList.remove('on');
    e.textContent = 'ADDED'; btn.textContent = 'Undo'; line.style.display = 'none';
    await wait(2000); n.classList.remove('on'); await wait(900); if (!alive()) return;
    $$('.caret', field).forEach(c => c.remove());
    key.classList.add('down'); h.show(); h.text.innerHTML = ''; await wait(400);
    if (!await flow(h.text, 'the Vercel build is green', PACE * 2.2, alive)) return h.hide();
    await wait(400); key.classList.remove('down'); h.hide(); await wait(320);
    field.append('\n'); const t = document.createElement('span'); field.append(t);
    if (!await flow(t, 'The Vercel build is green.', 16, alive)) return;
    field.insertAdjacentHTML('beforeend', '<span class="caret"></span>');
    await wait(3500);
  };

  // A Google Meet call: SigmaFlow asks to record it.
  SCENES.meet = async (d, alive) => {
    const card = $('.sf-call', d), bar = $('.sf-line i', card), sound = $('[data-b="sound"]', card), ptr = $('.pointer', d), tiles = $$('.tile', d);
    card.classList.remove('on'); sound.classList.remove('press'); ptr.classList.remove('on');
    let k = 0; const talk = setInterval(() => { tiles.forEach((t, j) => t.classList.toggle('talk', j === k % 3)); k++; }, 1400);
    try {
      if (!await wait(1400) || !alive()) return;
      bar.style.transition = 'none'; bar.style.transform = 'scaleX(1)'; card.classList.add('on');
      void bar.offsetWidth; bar.style.transition = 'transform 20s linear'; bar.style.transform = 'scaleX(0)';
      await wait(1600); if (!alive()) return;
      ptr.style.left = '70%'; ptr.style.top = '40%'; ptr.classList.add('on'); await wait(100);
      pointTo(d, ptr, sound, .45, .6); await wait(1100); if (!alive()) return;
      sound.classList.add('press'); await wait(220); card.classList.remove('on'); await wait(500); ptr.classList.remove('on');
      await wait(5200);
    } finally { clearInterval(talk); }
  };

  // Live notes in a room: the card writes the conversation down beside the slides.
  SCENES.livenotes = async (d, alive) => {
    const el = $('.sf-notes', d), h = hud(el), list = $('.sf-lines', d);
    list.innerHTML = ''; h.show(); const tm = $('.tm', el); let s = 662; tm.textContent = '11:02';
    const clock = setInterval(() => { s++; tm.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; }, 1000);
    const lines = [
      ['11:02', 'So the launch runs on three channels: email, LinkedIn and the webinar.'],
      ['11:06', 'Email goes out a week before the webinar.', true],
      ['11:10', 'Take a photo of the whiteboard before we wipe it.'],
      ['11:14', 'Sam owns the LinkedIn posts, and I’ll draft the email.']
    ];
    try {
      for (const [t, text, photo] of lines) {
        if (!await wait(700) || !alive()) return;
        const row = document.createElement('div'); row.className = 'sf-ln';
        row.innerHTML = `<span class="tm">${t}</span><div><span class="tx"></span>${photo ? '<div class="ph" style="margin-top:8px"></div>' : ''}</div>`;
        list.append(row);
        if (!await flow($('.tx', row), text, PACE * 2, alive)) return;
      }
      await wait(4000);
    } finally { clearInterval(clock); h.quiet(); }
  };

  // Claude Desktop answers from your meetings, through SigmaFlow.
  SCENES.claude = async (d, alive) => {
    const tools = $$('.toolrow', d), ans = $('.ans', d), you = $('.you', d);
    tools.forEach(t => t.style.display = 'none'); ans.innerHTML = ''; you.style.opacity = 0;
    if (!await wait(600) || !alive()) return;
    you.style.transition = 'opacity .3s'; you.style.opacity = 1;
    for (const t of tools) { await wait(900); if (!alive()) return; t.style.display = ''; }
    await wait(700);
    if (!await flow(ans, 'Two things, from the Northwind discovery call on 22 October:\n\n1. SSO. Their security team won’t sign off on anything without it.\n2. Pricing for 40 seats, with the quote by Friday.\n\nThey also asked for a two-week pilot with five reps.', 45, alive)) return;
    await wait(4500);
  };

  /* ---------- the hero: three apps, and your own Right Command ---------- */
  function hero(desk) {
    const items = [
      { win: 'slack', app: 'Slack', on: 'slack',
        said: 'yes, um, the webinar is on Thursday the 12th, and the email goes out a week before',
        wrote: 'Yes, the webinar is on Thursday the 12th, and the email goes out a week before.' },
      { win: 'gmail', app: 'Google Chrome', on: 'chrome',
        said: 'hi Jon, uh, the pilot runs for two weeks with five reps, and we review the numbers together after',
        wrote: 'Hi Jon, the pilot runs for two weeks with five reps, and we review the numbers together after.' },
      { win: 'cursor', app: 'Cursor', on: 'cursor',
        said: 'um, make the signup form show an error when the email is already taken',
        wrote: 'Make the signup form show an error when the email is already taken.' }
    ];
    const h = hud($('.sf-hud', desk)), key = $('.sf-key', desk), tabs = $$('.shot-tab');
    let ix = 0, run = 0, held = false, user = false;
    const field = () => $(`[data-app-win="${items[ix].win}"] [data-field]`, desk);
    const ready = on => $$(`[data-app-win="${items[ix].win}"] .send, [data-app-win="${items[ix].win}"] .go`, desk).forEach(b => b.classList.toggle('ready', on));
    function show(i) {
      ix = i;
      $$('[data-app-win]', desk).forEach(w => w.classList.toggle('hide', w.dataset.appWin !== items[i].win));
      setApp(desk, items[i].app, items[i].on);
      tabs.forEach((t, k) => t.classList.toggle('on', k === i));
      blank(field()); ready(false); h.text.innerHTML = '';
    }
    async function play(i) {
      const id = ++run, alive = () => id === run;
      show(i); await wait(1000); if (!alive()) return;
      key.classList.add('down'); h.show(); await wait(450); if (!alive()) return;
      if (!await flow(h.text, items[i].said, PACE * 2.2, alive)) return;
      await wait(600); if (!alive()) return;
      key.classList.remove('down'); h.hide(); await wait(320); if (!alive()) return;
      if (!await land(field(), items[i].wrote, alive)) return;
      ready(true);
      await wait(3600); if (!alive() || user) return;
      play((i + 1) % items.length);
    }
    async function press() {
      if (held) return; held = true; user = true;
      const id = ++run; show(ix); key.classList.add('down'); h.show();
      await flow(h.text, items[ix].said, PACE * 2.2, () => id === run && held);
    }
    async function release() {
      if (!held) return; held = false;
      const id = ++run, alive = () => id === run;
      h.text.textContent = items[ix].said; key.classList.remove('down'); h.hide(); await wait(320);
      if (await land(field(), items[ix].wrote, alive)) ready(true);
      setTimeout(() => { if (alive() && !held) { user = false; play((ix + 1) % items.length); } }, 4500);
    }
    const hold = $('#holdKey');
    if (hold) {
      hold.addEventListener('pointerdown', e => { e.preventDefault(); hold.setPointerCapture(e.pointerId); press(); });
      hold.addEventListener('pointerup', release); hold.addEventListener('pointercancel', release);
    }
    addEventListener('keydown', e => { if (e.code === 'MetaRight' && !e.repeat) press(); });
    addEventListener('keyup', e => { if (e.code === 'MetaRight') release(); });
    addEventListener('blur', release);
    tabs.forEach((t, k) => t.addEventListener('click', () => { user = false; play(k); }));
    play(0);
  }

  /* ---------- start everything ---------- */
  $$('.desk').forEach(dress);
  $$('.desk-box').forEach(box => { new ResizeObserver(() => fit(box)).observe(box); fit(box); });
  $$('.desk').forEach(desk => {
    if (desk.dataset.scene === 'hero') return hero(desk);
    const fn = SCENES[desk.dataset.scene]; if (!fn) return;
    let token = 0, running = false;
    new IntersectionObserver(([e]) => {
      if (e.isIntersecting && !running) {
        running = true; const id = ++token, alive = () => id === token;
        (async () => { while (alive()) { const t0 = performance.now(); await fn(desk, alive); if (performance.now() - t0 < 50) await wait(500); } })();
      } else if (!e.isIntersecting && running) { running = false; token++; }
    }, { threshold: .3 }).observe(desk.parentElement);
  });

  /* ---------- the keyboard of apps you already use ---------- */
  const kb = $('#kb');
  if (kb) {
    const apps = ['slack', 'gmail', 'cursor', 'claude', 'chatgpt', 'notion', 'linear', 'figma', 'obsidian', 'vscode', 'xcode',
      'mail', 'notes', 'messages', 'whatsapp', 'discord', 'docs', 'sheets', 'word', 'safari', 'chrome', 'arc',
      'dia', 'terminal', 'zoom', 'meet', 'facetime', 'calendar', 'reminders', 'textedit', 'freeform', 'slides'];
    const NAMES = { slack: 'Slack', gmail: 'Gmail', cursor: 'Cursor', claude: 'Claude', chatgpt: 'ChatGPT', notion: 'Notion', linear: 'Linear', figma: 'Figma', obsidian: 'Obsidian', vscode: 'VS Code', xcode: 'Xcode', mail: 'Mail', notes: 'Notes', messages: 'Messages', whatsapp: 'WhatsApp', discord: 'Discord', docs: 'Google Docs', sheets: 'Google Sheets', word: 'Word', safari: 'Safari', chrome: 'Chrome', arc: 'Arc', dia: 'Dia', terminal: 'Terminal', zoom: 'Zoom', meet: 'Google Meet', facetime: 'FaceTime', calendar: 'Calendar', reminders: 'Reminders', textedit: 'TextEdit', freeform: 'Freeform', slides: 'Google Slides' };
    let a = 0;
    const rows = [
      Array(14).fill(1),
      [1.5, ...Array(11).fill('i'), 1.5],
      [1.8, ...Array(11).fill('i'), 1.2],
      [2.3, ...Array(10).fill('i'), 1.7],
      [1, 1, 1.2, 6.1, 1.2, 1, 1, 1.5]
    ];
    kb.innerHTML = rows.map(r => `<div class="kb-row">${r.map(k => {
      if (k === 'i') { const app = apps[a++]; return `<span class="kb-key app" style="background-image:url('${ICON[app]}')" title="${NAMES[app]}" role="img" aria-label="${NAMES[app]}"></span>`; }
      return `<span class="kb-key" style="flex-grow:${k}"></span>`;
    }).join('')}</div>`).join('');
    const keys = $$('.kb-key.app', kb);
    if (!reduce) setInterval(() => { const k = keys[Math.floor(Math.random() * keys.length)]; k.classList.add('press'); setTimeout(() => k.classList.remove('press'), 180); }, 420);
  }
})();
