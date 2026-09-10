/*
 * Aegora — widget de webchat mínimo (V1).
 * Embebido:
 *   <script src="https://TU-CDN/widget.js"
 *           data-endpoint="https://n8n.tu-dominio/webhook/webchat"
 *           data-title="Asistente"></script>
 *
 * POST {endpoint}  ->  { session_key, message }
 * respuesta        <-  { reply, needs_user_reply, client_session_id }
 *
 * Sin dependencias. Guarda el id de hilo en localStorage. Una petición en vuelo.
 */
(function () {
  var script = document.currentScript;
  if (!script) return;
  var ENDPOINT = script.getAttribute('data-endpoint');
  var TITLE = script.getAttribute('data-title') || 'Asistente';
  var GREETING = script.getAttribute('data-greeting') || '¡Hola! ¿En qué puedo ayudarte?';
  if (!ENDPOINT) { console.error('[aegora-webchat] falta data-endpoint'); return; }

  var SKEY = 'aegora_webchat_sid';
  var sid = null;
  try { sid = localStorage.getItem(SKEY); } catch (e) {}

  var css = '' +
    '.agw-btn{position:fixed;right:20px;bottom:20px;width:56px;height:56px;border-radius:50%;border:0;' +
      'background:#1f6feb;color:#fff;font-size:24px;cursor:pointer;box-shadow:0 4px 16px rgba(0,0,0,.25);z-index:2147483000}' +
    '.agw-panel{position:fixed;right:20px;bottom:88px;width:340px;max-width:calc(100vw - 40px);height:460px;' +
      'max-height:calc(100vh - 120px);background:#fff;border-radius:12px;box-shadow:0 8px 32px rgba(0,0,0,.28);' +
      'display:none;flex-direction:column;overflow:hidden;z-index:2147483000;font:14px/1.4 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}' +
    '.agw-panel.agw-open{display:flex}' +
    '.agw-head{background:#1f6feb;color:#fff;padding:12px 14px;font-weight:600;display:flex;justify-content:space-between;align-items:center}' +
    '.agw-head button{background:transparent;border:0;color:#fff;font-size:18px;cursor:pointer;line-height:1}' +
    '.agw-log{flex:1;overflow-y:auto;padding:12px;display:flex;flex-direction:column;gap:8px;background:#f6f8fa}' +
    '.agw-msg{max-width:80%;padding:8px 11px;border-radius:12px;white-space:pre-wrap;word-wrap:break-word}' +
    '.agw-user{align-self:flex-end;background:#1f6feb;color:#fff;border-bottom-right-radius:3px}' +
    '.agw-bot{align-self:flex-start;background:#fff;border:1px solid #d0d7de;border-bottom-left-radius:3px}' +
    '.agw-form{display:flex;border-top:1px solid #d0d7de;background:#fff}' +
    '.agw-form input{flex:1;border:0;padding:12px;font:inherit;outline:none}' +
    '.agw-form button{border:0;background:#1f6feb;color:#fff;padding:0 16px;cursor:pointer;font:inherit}' +
    '.agw-form button:disabled{opacity:.5;cursor:default}' +
    '.agw-dots{align-self:flex-start;color:#57606a;font-style:italic}';
  var style = document.createElement('style');
  style.textContent = css;
  document.head.appendChild(style);

  var btn = document.createElement('button');
  btn.className = 'agw-btn';
  btn.setAttribute('aria-label', 'Abrir chat');
  btn.textContent = '💬';

  var panel = document.createElement('div');
  panel.className = 'agw-panel';
  panel.innerHTML =
    '<div class="agw-head"><span></span><button aria-label="Cerrar">×</button></div>' +
    '<div class="agw-log"></div>' +
    '<form class="agw-form"><input type="text" placeholder="Escribe un mensaje…" autocomplete="off" ' +
      'aria-label="Mensaje"><button type="submit">Enviar</button></form>';
  panel.querySelector('.agw-head span').textContent = TITLE;

  document.body.appendChild(btn);
  document.body.appendChild(panel);

  var log = panel.querySelector('.agw-log');
  var form = panel.querySelector('.agw-form');
  var input = form.querySelector('input');
  var sendBtn = form.querySelector('button');
  var greeted = false;

  function add(text, who) {
    var el = document.createElement('div');
    el.className = 'agw-msg ' + (who === 'user' ? 'agw-user' : 'agw-bot');
    el.textContent = text;
    log.appendChild(el);
    log.scrollTop = log.scrollHeight;
    return el;
  }

  function toggle() {
    var open = panel.classList.toggle('agw-open');
    if (open) {
      if (!greeted) { add(GREETING, 'bot'); greeted = true; }
      input.focus();
    }
  }
  btn.addEventListener('click', toggle);
  panel.querySelector('.agw-head button').addEventListener('click', toggle);

  form.addEventListener('submit', function (ev) {
    ev.preventDefault();
    var text = input.value.trim();
    if (!text || sendBtn.disabled) return;
    add(text, 'user');
    input.value = '';
    sendBtn.disabled = true;
    input.disabled = true;
    var dots = document.createElement('div');
    dots.className = 'agw-dots';
    dots.textContent = '…';
    log.appendChild(dots);
    log.scrollTop = log.scrollHeight;

    fetch(ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message: text, session_key: sid })
    })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (data && data.client_session_id) {
          sid = data.client_session_id;
          try { localStorage.setItem(SKEY, sid); } catch (e) {}
        }
        dots.remove();
        add((data && data.reply) || 'Ahora mismo no puedo responder. Inténtalo en un momento.', 'bot');
      })
      .catch(function () {
        dots.remove();
        add('Ha habido un problema de conexión. Inténtalo de nuevo.', 'bot');
      })
      .finally(function () {
        sendBtn.disabled = false;
        input.disabled = false;
        input.focus();
      });
  });
})();
