const statusLine = document.getElementById('status');
async function render() {
  const { status, lastSync, tabCount } = await chrome.storage.local.get(['status', 'lastSync', 'tabCount']);
  const age = lastSync ? Math.round((Date.now() - lastSync) / 1000) : null;
  if (age !== null && age < 10 && status === '已连接') {
    statusLine.textContent = `✅ 已连接 StepBar · 同步 ${tabCount ?? '?'} 个标签页 · ${age} 秒前`;
  } else if (status && status !== '已连接') {
    statusLine.textContent = `⚠️ 连接失败：${status}（请确认 StepBar 正在运行）`;
  } else {
    statusLine.textContent = age === null ? '正在连接…' : `⚠️ ${age} 秒未同步，请确认 StepBar 正在运行`;
  }
}
setInterval(render, 1000);
render();
