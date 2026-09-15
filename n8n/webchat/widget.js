/*
 * Aegora — widget de webchat mínimo (V1).
 * Embebido:
 *   <script src="https://TU-CDN/widget.js"
 *           data-endpoint="https://n8n.tu-dominio/webhook/webchat"
 *           data-title="Asistente"
 *           data-privacy-url="https://tu-dominio/legal/privacidad"></script>
 *
 * POST {endpoint}  ->  { session_key, message }
 * respuesta        <-  { reply, needs_user_reply, client_session_id }
 *
 * Aviso de privacidad (RGPD art. 13): aquí se enseña al ABRIR el chat, no colgado de la
 * primera respuesta. En webchat existe ese momento y en WhatsApp no, que es justo por lo
 * que allí viaja como botón en el primer mensaje. El adapter de webchat manda ya la
 * respuesta sin el aviso, para que no salga dos veces.
 *
 * Sin dependencias. Guarda el id de hilo en localStorage. Una petición en vuelo.
 */
(function () {
  var script = document.currentScript;
  if (!script) return;
  var ENDPOINT = script.getAttribute('data-endpoint');
  var TITLE = script.getAttribute('data-title') || 'Asistente';
  var GREETING = script.getAttribute('data-greeting') || '¡Hola! ¿En qué puedo ayudarte?';
  var PRIV_URL = script.getAttribute('data-privacy-url') || '';
  var PRIV_TEXT = script.getAttribute('data-privacy-text') ||
    'Guardamos tus datos solo para gestionar tu cita.';
  // Aquí no hay límite de 20 caracteres como en los botones de WhatsApp: cabe el nombre entero.
  var PRIV_LABEL = script.getAttribute('data-privacy-label') || 'Política de Privacidad';
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
    // El texto del bot se renderiza (negritas, listas, enlaces), así que los saltos ya van
    // en <br>/<li> y pre-wrap sobraría: duplicaría el espaciado.
    '.agw-bot{align-self:flex-start;background:#fff;border:1px solid #d0d7de;border-bottom-left-radius:3px;' +
      'white-space:normal}' +
    '.agw-bot ul{margin:4px 0;padding-left:18px}' +
    '.agw-bot li{margin:1px 0}' +
    '.agw-bot code{background:#f0f2f4;border-radius:4px;padding:0 3px;font-size:.92em}' +
    '.agw-bot a{color:#1f6feb}' +
    '.agw-form{display:flex;border-top:1px solid #d0d7de;background:#fff}' +
    '.agw-form input{flex:1;border:0;padding:12px;font:inherit;outline:none}' +
    '.agw-form button{border:0;background:#1f6feb;color:#fff;padding:0 16px;cursor:pointer;font:inherit}' +
    '.agw-form button:disabled{opacity:.5;cursor:default}' +
    '.agw-dots{align-self:flex-start;color:#57606a;font-style:italic}' +
    // Nota legal, no un mensaje de Lucía: se distingue a propósito de las burbujas.
    '.agw-priv{align-self:stretch;color:#57606a;font-size:12px;line-height:1.5;text-align:center;' +
      'padding:2px 6px 6px}' +
    '.agw-priv a{color:#1f6feb}';
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

  function esc(s) {
    return s.replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  /*
   * Markdown mínimo del texto de Lucía. El agente redacta libre y usa markdown; sin esto
   * se ven los asteriscos crudos. SIEMPRE se escapa primero y solo después se inyecta el
   * HTML que generamos aquí, así que el texto del modelo nunca puede traer etiquetas.
   * Los href salen de un patrón que solo acepta http(s).
   */
  function render(text) {
    var t = esc(text)
      .replace(/^#{1,6}\s*(.+)$/gm, '<b>$1</b>')
      .replace(/\*\*\*(.+?)\*\*\*/g, '<b><i>$1</i></b>')
      .replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')
      .replace(/(^|[\s(])_(.+?)_(?=[\s.,;:!?)]|$)/g, '$1<i>$2</i>')
      .replace(/`(.+?)`/g, '<code>$1</code>')
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g,
               '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
      .replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g,
               '$1<a href="$2" target="_blank" rel="noopener noreferrer">$2</a>');

    var html = '';
    var enLista = false;
    t.split('\n').forEach(function (ln) {
      var punto = ln.match(/^\s*[-*+]\s+(.*)$/) || ln.match(/^\s*\d+[.)]\s+(.*)$/);
      if (punto) {
        if (!enLista) { html += '<ul>'; enLista = true; }
        html += '<li>' + punto[1] + '</li>';
      } else {
        if (enLista) { html += '</ul>'; enLista = false; }
        html += ln ? ln + '<br>' : '<br>';
      }
    });
    if (enLista) html += '</ul>';
    return html.replace(/(<br>)+$/, '');
  }

  function add(text, who) {
    var el = document.createElement('div');
    el.className = 'agw-msg ' + (who === 'user' ? 'agw-user' : 'agw-bot');
    // Lo que escribe el usuario nunca se renderiza: va tal cual.
    if (who === 'user') el.textContent = text;
    else el.innerHTML = render(text);
    log.appendChild(el);
    log.scrollTop = log.scrollHeight;
    return el;
  }

  function addPrivacy() {
    var el = document.createElement('div');
    el.className = 'agw-priv';
    el.appendChild(document.createTextNode(PRIV_TEXT + ' '));
    // Solo http(s): un data-privacy-url con javascript: no debe llegar a un href.
    if (/^https?:\/\//i.test(PRIV_URL)) {
      var a = document.createElement('a');
      a.href = PRIV_URL;
      a.target = '_blank';
      a.rel = 'noopener noreferrer';
      a.textContent = PRIV_LABEL;
      el.appendChild(a);
    }
    log.appendChild(el);
  }

  function toggle() {
    var open = panel.classList.toggle('agw-open');
    if (open) {
      if (!greeted) {
        addPrivacy();
        add(GREETING, 'bot');
        greeted = true;
      }
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
