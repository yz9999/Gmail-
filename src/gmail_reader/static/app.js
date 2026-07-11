(() => {
  const state = {
    view: 'inbox',
    messages: [],
    selected: null,
    query: '',
    loading: false,
    accounts: [],
    account: localStorage.getItem('gmailAccountId') || null,
    detailToken: null,
    page: 1,
    pageSize: 50,
    total: 0,
    hasNext: false,
    messagesController: null,
    detailController: null,
  };

  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => [...document.querySelectorAll(selector)];
  const listPanel = $('#listPanel');
  const detailPanel = $('#detailPanel');
  const messageList = $('#messageList');
  const toast = $('#toast');
  let toastTimer;

  function showToast(message, duration = 3500) {
    clearTimeout(toastTimer);
    toast.textContent = message;
    toast.classList.remove('hidden');
    toastTimer = setTimeout(() => toast.classList.add('hidden'), duration);
  }

  async function api(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || `请求失败 (${response.status})`);
    return data;
  }

  function selectedAccount() {
    return state.accounts.find((account) => account.id === state.account) || null;
  }

  function accountQuery() {
    return state.account ? `&account=${encodeURIComponent(state.account)}` : '';
  }

  function accountInitial(account) {
    return ((account?.name || account?.address || 'G').trim()[0] || 'G').toUpperCase();
  }

  function renderAccounts() {
    const current = selectedAccount();
    const initial = accountInitial(current);
    $('#avatarButton').textContent = initial;
    $('#largeAvatar').textContent = initial;
    $('#currentAccountName').textContent = current?.name || 'Gmail';
    $('#currentAccountAddress').textContent = current?.address || '尚未配置账号';
    $('#accountList').replaceChildren();

    for (const account of state.accounts) {
      const row = document.createElement('div');
      row.className = `account-row${account.id === state.account ? ' selected' : ''}`;
      row.setAttribute('role', 'button');
      row.tabIndex = 0;

      const avatar = document.createElement('span');
      avatar.className = 'account-row-avatar';
      avatar.textContent = accountInitial(account);
      const info = document.createElement('span');
      info.className = 'account-row-info';
      const name = document.createElement('strong');
      name.textContent = account.name;
      const address = document.createElement('span');
      address.textContent = account.address;
      info.append(name, address);
      row.append(avatar, info);

      if (account.deletable) {
        const remove = document.createElement('button');
        remove.className = 'delete-account';
        remove.type = 'button';
        remove.title = '移除账号';
        remove.innerHTML = '<span class="material-symbols-outlined">delete</span>';
        remove.addEventListener('click', async (event) => {
          event.stopPropagation();
          if (!window.confirm(`从本机移除 ${account.address}？`)) return;
          try {
            await api(`/api/accounts/${encodeURIComponent(account.id)}`, { method: 'DELETE' });
            if (state.account === account.id) state.account = null;
            await loadAccounts();
            state.page = 1;
            state.total = 0;
            state.hasNext = false;
            await loadMessages();
            showToast('账号已移除');
          } catch (error) { showToast(error.message); }
        });
        row.append(remove);
      }

      row.addEventListener('click', () => selectAccount(account.id));
      row.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') selectAccount(account.id);
      });
      $('#accountList').append(row);
    }
  }

  async function loadAccounts(preferredId = null) {
    state.accounts = await api('/api/accounts');
    const wanted = preferredId || state.account;
    state.account = state.accounts.some((item) => item.id === wanted)
      ? wanted
      : state.accounts[0]?.id || null;
    if (state.account) localStorage.setItem('gmailAccountId', state.account);
    else localStorage.removeItem('gmailAccountId');
    renderAccounts();
  }

  function selectAccount(accountId) {
    if (state.account === accountId) {
      $('#accountMenu').classList.add('hidden');
      return;
    }
    state.account = accountId;
    localStorage.setItem('gmailAccountId', accountId);
    state.view = 'inbox';
    state.page = 1;
    state.total = 0;
    state.hasNext = false;
    state.messages = [];
    state.selected = null;
    $$('.nav-item[data-view]').forEach((item) => item.classList.toggle('active', item.dataset.view === 'inbox'));
    closeDetail();
    renderAccounts();
    $('#accountMenu').classList.add('hidden');
    loadMessages();
  }

  function skeleton() {
    messageList.replaceChildren();
    for (let i = 0; i < 12; i += 1) {
      const row = document.createElement('div');
      row.className = 'skeleton-row';
      row.innerHTML = '<span></span><span></span><span></span><span></span>';
      messageList.append(row);
    }
  }

  function emptyState(title, detail, icon = 'inbox') {
    const box = document.createElement('div');
    box.className = 'empty-state';
    const iconEl = document.createElement('span');
    iconEl.className = 'material-symbols-outlined';
    iconEl.textContent = icon;
    const strong = document.createElement('strong');
    strong.textContent = title;
    const text = document.createElement('span');
    text.textContent = detail;
    box.append(iconEl, strong, text);
    messageList.replaceChildren(box);
  }

  function isFlagged(message, flag) {
    return message.flags.some((item) => item.toLowerCase() === flag.toLowerCase());
  }

  function senderName(sender) {
    if (!sender) return '（未知发件人）';
    const angle = sender.indexOf('<');
    return (angle > 0 ? sender.slice(0, angle) : sender.split('@')[0]).replace(/^['"]|['"]$/g, '').trim();
  }

  function formatDate(raw) {
    const date = new Date(raw);
    if (Number.isNaN(date.getTime())) return raw || '';
    const now = new Date();
    if (date.toDateString() === now.toDateString()) {
      return new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', hour12: false }).format(date);
    }
    if (date.getFullYear() === now.getFullYear()) {
      return new Intl.DateTimeFormat('zh-CN', { month: 'short', day: 'numeric' }).format(date);
    }
    return new Intl.DateTimeFormat('zh-CN', { year: 'numeric', month: 'numeric', day: 'numeric' }).format(date);
  }

  function safeEmailDocument(rawHtml) {
    const parsed = new DOMParser().parseFromString(rawHtml || '', 'text/html');
    parsed.querySelectorAll('script, iframe, frame, frameset, object, embed, form, input, button, textarea, select, meta[http-equiv="refresh"]').forEach((node) => node.remove());
    parsed.querySelectorAll('*').forEach((node) => {
      for (const attribute of [...node.attributes]) {
        const name = attribute.name.toLowerCase();
        const value = attribute.value.trim().toLowerCase();
        if (name.startsWith('on') || name === 'srcdoc') node.removeAttribute(attribute.name);
        if ((name === 'href' || name === 'src' || name === 'xlink:href') && value.startsWith('javascript:')) {
          node.removeAttribute(attribute.name);
        }
      }
    });

    const originalStyles = parsed.head.querySelectorAll('style, link[rel="stylesheet"]');
    const styles = [...originalStyles].map((node) => node.outerHTML).join('');
    const content = parsed.body.innerHTML;
    return `<!doctype html>
      <html><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data: cid:; style-src 'unsafe-inline' https: http:; font-src https: http: data:; frame-src 'none'; media-src https: http: data:; script-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
      ${styles}
      <style>
        html,body{margin:0;padding:0;background:#fff;color:#202124;max-width:100%;overflow-x:auto}
        body{font-family:Arial,Helvetica,sans-serif;line-height:1.45}
        img{max-width:100%;height:auto}
        table{max-width:100%}
        a{color:#0b57d0}
      </style></head><body>${content}</body></html>`;
  }

  function renderMessageBody(message) {
    const frame = $('#detailHtml');
    const plain = $('#detailText');
    if (!message.body_html) {
      frame.classList.add('hidden');
      frame.removeAttribute('srcdoc');
      plain.classList.remove('hidden');
      plain.textContent = message.body || '（无文本正文）';
      return;
    }

    plain.classList.add('hidden');
    frame.classList.remove('hidden');
    frame.onload = () => {
      const document = frame.contentDocument;
      if (!document) return;

      const resize = () => {
        const height = Math.max(
          document.documentElement.scrollHeight,
          document.body?.scrollHeight || 0,
          240,
        );
        frame.style.height = `${Math.min(height + 8, 4000)}px`;
      };
      resize();
      setTimeout(resize, 250);
      setTimeout(resize, 1200);
      document.addEventListener('click', (event) => {
        const link = event.target.closest?.('a[href]');
        if (!link) return;
        event.preventDefault();
        const href = link.getAttribute('href');
        if (href && /^(https?:|mailto:)/i.test(href)) window.open(href, '_blank', 'noopener,noreferrer');
      });
    };
    frame.srcdoc = safeEmailDocument(message.body_html);
  }

  function filteredMessages() {
    const query = state.query.trim().toLocaleLowerCase();
    if (!query) return state.messages;
    return state.messages.filter((message) =>
      [message.sender, message.subject, message.body].some((value) => (value || '').toLocaleLowerCase().includes(query))
    );
  }

  function renderMessages() {
    const messages = filteredMessages();
    messageList.replaceChildren();
    const start = state.total ? (state.page - 1) * state.pageSize + 1 : 0;
    const end = state.total ? Math.min(start + state.messages.length - 1, state.total) : 0;
    $('#rangeLabel').textContent = state.total ? `第 ${start}-${end} 行，共 ${state.total} 行` : '';
    $('#previousPageButton').classList.toggle('disabled', state.page <= 1);
    $('#previousPageButton').disabled = state.page <= 1;
    $('#nextPageButton').classList.toggle('disabled', !state.hasNext);
    $('#nextPageButton').disabled = !state.hasNext;
    $('#inboxCount').textContent = state.view === 'inbox'
      ? state.messages.filter((item) => !isFlagged(item, '\\Seen')).length || ''
      : '';

    if (!messages.length) {
      emptyState(state.query ? '没有匹配的邮件' : '这里没有邮件', state.query ? '请尝试其他搜索条件' : '新邮件到达后会显示在这里');
      return;
    }

    for (const message of messages) {
      const unread = !isFlagged(message, '\\Seen');
      const starred = isFlagged(message, '\\Flagged');
      const row = document.createElement('div');
      row.className = `message-row${unread ? ' unread' : ''}`;
      row.dataset.uid = message.uid;
      row.tabIndex = 0;

      const checkLabel = document.createElement('label');
      checkLabel.className = 'check-wrap';
      checkLabel.innerHTML = '<input type="checkbox" aria-label="选择邮件"><span class="custom-check"></span>';
      checkLabel.addEventListener('click', (event) => event.stopPropagation());

      const star = document.createElement('button');
      star.className = `icon-button small star-button${starred ? ' starred' : ''}`;
      star.setAttribute('aria-label', starred ? '取消星标' : '加星标');
      star.innerHTML = '<span class="material-symbols-outlined">star</span>';
      star.addEventListener('click', (event) => {
        event.stopPropagation();
        toggleStar(message, star);
      });

      const sender = document.createElement('div');
      sender.className = 'sender-cell';
      sender.textContent = senderName(message.sender);

      const content = document.createElement('div');
      content.className = 'content-cell';
      const subject = document.createElement('span');
      subject.className = 'content-subject';
      subject.textContent = message.subject || '（无主题）';
      const snippet = document.createElement('span');
      snippet.className = 'content-snippet';
      const compactBody = (message.body || '').replace(/\s+/g, ' ').trim();
      snippet.textContent = compactBody ? ` - ${compactBody}` : '';
      content.append(subject, snippet);

      const date = document.createElement('time');
      date.className = 'date-cell';
      date.textContent = formatDate(message.date);
      date.title = message.date || '';

      row.append(checkLabel, star, sender, content, date);
      row.addEventListener('click', () => openMessage(message));
      row.addEventListener('keydown', (event) => {
        if (event.key === 'Enter') openMessage(message);
      });
      messageList.append(row);
    }
  }

  async function loadMessages() {
    if (state.messagesController) state.messagesController.abort();
    const controller = new AbortController();
    state.messagesController = controller;
    state.loading = true;
    if (!state.messages.length) skeleton();
    $('#refreshButton').querySelector('span').style.animation = 'spin .8s linear infinite';
    try {
      if (!state.account) {
        state.total = 0;
        state.hasNext = false;
        emptyState('尚未添加账号', '点击右上角头像添加 Gmail 账号', 'person_add');
        return;
      }
      const requestedAccount = state.account;
      const requestedView = state.view;
      const requestedPage = state.page;
      const result = await api(
        `/api/messages?view=${encodeURIComponent(requestedView)}&limit=${state.pageSize}&page=${requestedPage}&account=${encodeURIComponent(requestedAccount)}`,
        { signal: controller.signal },
      );
      if (controller.signal.aborted || state.messagesController !== controller) return;
      state.messages = result.messages;
      state.total = result.total;
      state.page = result.page;
      state.hasNext = result.has_next;
      renderMessages();
    } catch (error) {
      if (error.name === 'AbortError') return;
      emptyState('无法加载邮件', error.message, 'cloud_off');
      showToast(error.message, 6000);
    } finally {
      if (state.messagesController === controller) {
        state.messagesController = null;
        state.loading = false;
        $('#refreshButton').querySelector('span').style.animation = '';
      }
    }
  }

  async function toggleStar(message, button = null) {
    const starred = isFlagged(message, '\\Flagged');
    const action = starred ? 'unstar' : 'star';
    try {
      await api(`/api/messages/${message.uid}/flags`, {
        method: 'POST',
        body: JSON.stringify({ view: state.view, action, account: state.account }),
      });
      message.flags = starred
        ? message.flags.filter((flag) => flag.toLowerCase() !== '\\flagged')
        : [...message.flags, '\\Flagged'];
      if (button) button.classList.toggle('starred', !starred);
      if (state.view === 'starred' && starred) {
        state.messages = state.messages.filter((item) => item.uid !== message.uid);
        state.total = Math.max(0, state.total - 1);
        renderMessages();
      }
    } catch (error) {
      showToast(error.message);
    }
  }

  async function openMessage(message) {
    if (state.detailController) state.detailController.abort();
    const controller = new AbortController();
    state.detailController = controller;
    const token = `${state.account}:${state.view}:${message.uid}:${Date.now()}`;
    state.detailToken = token;
    state.selected = message;
    $('#detailSubject').textContent = message.subject || '（无主题）';
    const name = senderName(message.sender);
    $('#detailSender').textContent = name;
    $('#detailSenderAddress').textContent = message.sender === name ? '' : message.sender;
    $('#senderAvatar').textContent = (name[0] || '?').toUpperCase();
    $('#detailDate').textContent = formatDate(message.date);
    $('#detailDate').title = message.date || '';
    if (message._bodyLoaded) {
      renderMessageBody(message);
    } else {
      $('#detailHtml').classList.add('hidden');
      $('#detailText').classList.remove('hidden');
      $('#detailText').textContent = '正在加载邮件内容…';
    }
    $('#detailStar').classList.toggle('starred', isFlagged(message, '\\Flagged'));
    listPanel.classList.add('hidden');
    detailPanel.classList.remove('hidden');

    if (!isFlagged(message, '\\Seen')) {
      message.flags.push('\\Seen');
      api(`/api/messages/${message.uid}/flags`, {
        method: 'POST',
        body: JSON.stringify({ view: state.view, action: 'read', account: state.account }),
      }).catch((error) => showToast(error.message));
    }

    if (message._bodyLoaded) {
      state.detailController = null;
      return;
    }

    try {
      const fullMessage = await api(
        `/api/messages/${message.uid}?view=${encodeURIComponent(state.view)}${accountQuery()}`,
        { signal: controller.signal },
      );
      if (state.detailToken !== token) return;
      fullMessage._bodyLoaded = true;
      state.selected = fullMessage;
      const index = state.messages.findIndex((item) => item.uid === message.uid);
      if (index >= 0) state.messages[index] = fullMessage;
      renderMessageBody(fullMessage);
    } catch (error) {
      if (error.name === 'AbortError') return;
      if (state.detailToken !== token) return;
      $('#detailText').textContent = `邮件内容加载失败：${error.message}`;
      showToast(error.message);
    } finally {
      if (state.detailController === controller) state.detailController = null;
    }
  }

  function closeDetail() {
    if (state.detailController) state.detailController.abort();
    state.detailController = null;
    detailPanel.classList.add('hidden');
    listPanel.classList.remove('hidden');
    state.selected = null;
    state.detailToken = null;
    renderMessages();
  }

  function switchView(view, button) {
    state.view = view;
    state.page = 1;
    state.query = '';
    $('#searchInput').value = '';
    $$('.nav-item[data-view]').forEach((item) => item.classList.remove('active'));
    button.classList.add('active');
    closeDetail();
    loadMessages();
    if (window.innerWidth <= 640) toggleMobileSidebar(false);
  }

  function toggleMobileSidebar(open) {
    $('#sidebar').classList.toggle('mobile-open', open);
    $('#mobileScrim').classList.toggle('hidden', !open);
  }

  function openCompose() {
    $('#composeWindow').classList.remove('hidden', 'minimized');
    setTimeout(() => $('#composeTo').focus(), 0);
  }

  function closeCompose(clear = false) {
    $('#composeWindow').classList.add('hidden');
    if (clear) $('#composeForm').reset();
  }

  $$('.nav-item[data-view]').forEach((button) => {
    button.addEventListener('click', () => switchView(button.dataset.view, button));
  });
  $('#refreshButton').addEventListener('click', loadMessages);
  $('#previousPageButton').addEventListener('click', () => {
    if (state.page <= 1 || state.loading) return;
    state.page -= 1;
    state.messages = [];
    closeDetail();
    loadMessages();
  });
  $('#nextPageButton').addEventListener('click', () => {
    if (!state.hasNext || state.loading) return;
    state.page += 1;
    state.messages = [];
    closeDetail();
    loadMessages();
  });
  $('#backButton').addEventListener('click', closeDetail);
  $('#detailStar').addEventListener('click', () => state.selected && toggleStar(state.selected, $('#detailStar')));
  $('#detailUnread').addEventListener('click', async () => {
    if (!state.selected) return;
    try {
      await api(`/api/messages/${state.selected.uid}/flags`, {
        method: 'POST', body: JSON.stringify({ view: state.view, action: 'unread', account: state.account }),
      });
      state.selected.flags = state.selected.flags.filter((flag) => flag.toLowerCase() !== '\\seen');
      showToast('已标为未读');
    } catch (error) { showToast(error.message); }
  });

  $('#searchInput').addEventListener('input', (event) => {
    state.query = event.target.value;
    renderMessages();
  });
  $('#selectAll').addEventListener('change', (event) => {
    $$('.message-row input[type="checkbox"]').forEach((input) => { input.checked = event.target.checked; });
  });
  $('#moreButton').addEventListener('click', () => {
    $('#moreNav').classList.toggle('open');
    $('#moreButton .material-symbols-outlined').textContent = $('#moreNav').classList.contains('open') ? 'expand_less' : 'expand_more';
  });
  $('#toolbarMoreButton').addEventListener('click', (event) => {
    event.stopPropagation();
    $('#toolbarMenu').classList.toggle('hidden');
  });
  $('#toolbarMenu').addEventListener('click', (event) => event.stopPropagation());
  $('#markAllReadButton').addEventListener('click', async () => {
    if (!state.account) {
      showToast('请先选择 Gmail 账号');
      return;
    }
    const button = $('#markAllReadButton');
    button.disabled = true;
    try {
      const result = await api('/api/messages/mark-all-read', {
        method: 'POST',
        body: JSON.stringify({ view: state.view, account: state.account }),
      });
      if (state.view === 'unread') {
        state.messages = [];
        state.total = 0;
        state.hasNext = false;
      } else {
        for (const message of state.messages) {
          if (!isFlagged(message, '\\Seen')) message.flags.push('\\Seen');
        }
      }
      renderMessages();
      $('#toolbarMenu').classList.add('hidden');
      showToast(result.count ? `已将 ${result.count} 封邮件标记为已读` : '没有未读邮件');
    } catch (error) {
      showToast(error.message, 6000);
    } finally {
      button.disabled = false;
    }
  });
  $('#menuButton').addEventListener('click', () => {
    if (window.innerWidth <= 640) toggleMobileSidebar(!$('#sidebar').classList.contains('mobile-open'));
    else $('#sidebar').classList.toggle('collapsed');
  });
  $('#mobileScrim').addEventListener('click', () => toggleMobileSidebar(false));

  $('#composeButton').addEventListener('click', openCompose);
  $('#closeCompose').addEventListener('click', () => closeCompose(false));
  $('#discardCompose').addEventListener('click', () => closeCompose(true));
  $('#minimizeCompose').addEventListener('click', () => $('#composeWindow').classList.toggle('minimized'));
  $('#composeForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const sendButton = event.target.querySelector('.send-button');
    sendButton.disabled = true;
    try {
      await api('/api/send', {
        method: 'POST',
        body: JSON.stringify({
          to: $('#composeTo').value,
          subject: $('#composeSubject').value,
          body: $('#composeBody').value,
          account: state.account,
        }),
      });
      closeCompose(true);
      showToast('邮件已发送');
    } catch (error) {
      showToast(error.message, 6000);
    } finally {
      sendButton.disabled = false;
    }
  });

  const style = document.createElement('style');
  style.textContent = '@keyframes spin { to { transform: rotate(360deg); } }';
  document.head.append(style);

  $('#avatarButton').addEventListener('click', (event) => {
    event.stopPropagation();
    $('#accountMenu').classList.toggle('hidden');
  });
  $('#closeAccountMenu').addEventListener('click', () => $('#accountMenu').classList.add('hidden'));
  $('#accountMenu').addEventListener('click', (event) => event.stopPropagation());
  document.addEventListener('click', () => {
    $('#accountMenu').classList.add('hidden');
    $('#toolbarMenu').classList.add('hidden');
  });

  function openAccountDialog() {
    $('#accountMenu').classList.add('hidden');
    $('#accountModal').classList.remove('hidden');
    $('#accountError').classList.add('hidden');
    setTimeout(() => $('#accountName').focus(), 0);
  }

  function closeAccountDialog() {
    $('#accountModal').classList.add('hidden');
    $('#accountForm').reset();
    $('#accountPassword').type = 'password';
    $('#toggleAccountPassword .material-symbols-outlined').textContent = 'visibility';
  }

  $('#addAccountButton').addEventListener('click', openAccountDialog);
  $('#closeAccountDialog').addEventListener('click', closeAccountDialog);
  $('#cancelAccountDialog').addEventListener('click', closeAccountDialog);
  $('#accountModal').addEventListener('click', (event) => {
    if (event.target === $('#accountModal')) closeAccountDialog();
  });
  $('#toggleAccountPassword').addEventListener('click', () => {
    const password = $('#accountPassword');
    password.type = password.type === 'password' ? 'text' : 'password';
    $('#toggleAccountPassword .material-symbols-outlined').textContent = password.type === 'password' ? 'visibility' : 'visibility_off';
  });
  $('#accountForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const saveButton = $('#saveAccountButton');
    const errorBox = $('#accountError');
    saveButton.disabled = true;
    saveButton.textContent = '正在验证…';
    errorBox.classList.add('hidden');
    try {
      const result = await api('/api/accounts', {
        method: 'POST',
        body: JSON.stringify({
          name: $('#accountName').value,
          address: $('#accountAddress').value,
          app_password: $('#accountPassword').value,
        }),
      });
      closeAccountDialog();
      await loadAccounts(result.account.id);
      state.view = 'inbox';
      state.page = 1;
      await loadMessages();
      showToast('账号添加成功');
    } catch (error) {
      errorBox.textContent = error.message;
      errorBox.classList.remove('hidden');
    } finally {
      saveButton.disabled = false;
      saveButton.textContent = '验证并添加';
    }
  });

  async function initialize() {
    try {
      await loadAccounts();
      await loadMessages();
    } catch (error) {
      emptyState('账号配置加载失败', error.message, 'error');
      showToast(error.message, 6000);
    }
  }

  initialize();
})();
