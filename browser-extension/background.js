let endpoint = 'http://127.0.0.1:17373';
let busy = false;
// Chrome only: StepBar reads Chrome's history and talks to this one browser.
const bundle = 'com.google.Chrome';
// build.sh / StepBar write pairing.json next to this file, so loading the folder pairs automatically.
async function autoPair() {
  const stored = await chrome.storage.local.get(['token', 'pairedFile', 'port']);
  const lastPort = Number(stored.port);
  if (Number.isInteger(lastPort) && lastPort >= 17373 && lastPort <= 17393) endpoint = `http://127.0.0.1:${lastPort}`;
  const update = {};
  try {
    const file = await (await fetch(chrome.runtime.getURL('pairing.json'), { cache: 'no-store' })).json();
    if (file.token && file.token !== stored.pairedFile) { update.token = file.token; update.pairedFile = file.token; }
    const port = Number(file.port || 17373);
    if (Number.isInteger(port) && port >= 17373 && port <= 17393) {
      endpoint = `http://127.0.0.1:${port}`;
      if (port !== lastPort) update.port = port;
    }
  } catch (_) { /* Load the extension folder exported by StepBar to pair automatically. */ }
  if (Object.keys(update).length) await chrome.storage.local.set(update);
}
async function sync() {
  if (busy) return;
  busy = true;
  try {
    await autoPair(); // Follow the app's actual bound port without manual configuration or reload.
    const { token } = await chrome.storage.local.get(['token']);
    if (!token) return;
    const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-Browser-Bundle': bundle };
    const windows = await chrome.windows.getAll({ populate: true, windowTypes: ['normal'] });
    const tabs = windows.filter(w => !w.incognito).flatMap(w => (w.tabs || []).filter(t => !t.incognito).map(t => ({ id: t.id, windowID: w.id, title: t.title || '', url: t.url || '', active: t.active, focused: w.focused, bundle })));
    const report = await fetch(`${endpoint}/events`, { method: 'POST', headers, body: JSON.stringify({ bundle, tabs }), signal: AbortSignal.timeout(3000) });
    if (!report.ok) throw new Error(report.status === 401 ? '请在 StepBar 中重新安装扩展，并在 Chrome 中重新加载' : `连接失败（${report.status}）`);
    const response = await fetch(`${endpoint}/command`, { headers, signal: AbortSignal.timeout(3000) });
    const command = await response.json();
    if (command.id && command.bundle === bundle) {
      let success = false;
      if (command.probe === true) {
        success = true; // Authenticated round trip; do not focus or close any tab.
      } else if (Array.isArray(command.close)) {
        try { await chrome.tabs.remove(command.close); success = true; } catch (error) { console.warn('StepBar tab close failed', error.message); }
      } else try {
        const tab = await chrome.tabs.get(command.tabID);
        if (tab.windowId !== command.windowID) throw new Error('Tab moved');
        await chrome.tabs.update(command.tabID, { active: true });
        await chrome.windows.update(command.windowID, { focused: true });
        success = true;
      } catch (error) { console.warn('StepBar tab focus failed', error.message); }
      await fetch(`${endpoint}/ack`, { method: 'POST', headers, body: JSON.stringify({ id: command.id, success }), signal: AbortSignal.timeout(3000) });
    }
    await chrome.storage.local.set({ status: '已连接', lastSync: Date.now(), tabCount: tabs.length });
  } catch (error) { await chrome.storage.local.set({ status: error.message }); }
  finally { busy = false; }
}
// Page text, so the background model can tell what a page is for: only pages the user stays on for a few seconds, never incognito
// or pages with password fields, at most once per 12 hours per URL. Sent only to the local app.
let captureTimer = null;
function scheduleCapture() {
  clearTimeout(captureTimer);
  captureTimer = setTimeout(capture, 4000);
}
async function capture() {
  try {
    const { token } = await chrome.storage.local.get(['token']);
    if (!token) return;
    const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    if (!tab || tab.incognito || !/^https?:/.test(tab.url || '') || tab.status !== 'complete') return;
    const key = 'seen:' + tab.url.split('#')[0];
    const seen = (await chrome.storage.session.get(key))[key];
    if (seen && Date.now() - seen < 12 * 3600 * 1000) return;
    const [result] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: () => {
      if (document.querySelector('input[type=password]')) return null;
      const meta = document.querySelector('meta[name=description]')?.content || '';
      const main = document.querySelector('main, article, [role=main]') || document.body;
      return { title: document.title, text: (meta + ' ' + (main?.innerText || '')).slice(0, 3000) };
    } });
    if (!result?.result?.text?.trim()) return;
    const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-Browser-Bundle': bundle };
    const response = await fetch(`${endpoint}/page`, { method: 'POST', headers, body: JSON.stringify({ url: tab.url, ...result.result }), signal: AbortSignal.timeout(3000) });
    if (response.ok) await chrome.storage.session.set({ [key]: Date.now() });
  } catch (_) { /* chrome:// pages, store pages and closed tabs cannot be read */ }
}
chrome.tabs.onActivated.addListener(() => { sync(); scheduleCapture(); });
chrome.tabs.onUpdated.addListener((_id, change, tab) => {
  if (change.url || change.title || change.status === 'complete') sync();
  if (change.status === 'complete' && tab.active) scheduleCapture();
});
chrome.tabs.onRemoved.addListener(sync);
chrome.windows.onFocusChanged.addListener(() => { sync(); scheduleCapture(); });
chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());
chrome.runtime.onInstalled.addListener(() => { chrome.alarms.create('sync', { periodInMinutes: 0.5 }); autoPair().then(sync); });
chrome.runtime.onStartup.addListener(() => autoPair().then(sync));
chrome.alarms.onAlarm.addListener(sync);
chrome.storage.onChanged.addListener((_changes, area) => { if (area === 'local' && _changes.token) sync(); });
// While the worker is awake, keep commands and context fresh. Extension API calls in sync()
// reset the worker idle timer; alarms revive a suspended worker.
setInterval(sync, 2000);
autoPair().then(sync);
