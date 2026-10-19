const NATIVE_HOST = "com.passwordentry.auth";
const pendingTotps = new Map();
const PENDING_TOTP_TTL_MS = 90_000;

async function nativeRequest(request) {
  try {
    const response = await chrome.runtime.sendNativeMessage(NATIVE_HOST, request);
    if (!response?.ok) throw new Error(response?.error || "桌面端请求失败");
    return response;
  } catch (error) {
    throw new Error(error?.message || "Password Entry 桌面端未运行");
  }
}

chrome.tabs.onRemoved.addListener((tabId) => pendingTotps.delete(tabId));

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    switch (message.type) {
      case "GET_STATE": {
        try { const state = await nativeRequest({action: "status"}); sendResponse({ok: true, ...state, running: true}); }
        catch { sendResponse({ok: true, running: false, unlocked: false, initialized: false}); }
        break;
      }
      case "PAGE_HINT": {
        try {
          const state = await nativeRequest({action: "list_matches", url: message.url});
          const entries = (state.entries || []).map(({id, name, username, hasTotp, domains, origins}) => ({id, name, username, hasTotp, domains, origins}));
          sendResponse({ok: true, available: Boolean(entries.length), entries});
        }
        catch { sendResponse({ok: true, available: false, entries: []}); }
        break;
      }
      case "LIST_MATCHES": sendResponse({ok: true, ...(await nativeRequest({action: "list_matches", url: message.url}))}); break;
      case "CHECK_LOGIN": {
        if (!message.username || typeof message.password !== "string") { sendResponse({ok: true, existing: false, changed: false}); break; }
        let state;
        try { state = await nativeRequest({action: "list_matches", url: message.url}); }
        catch { sendResponse({ok: true, existing: false, changed: false}); break; }
        const match = (state.entries || []).find((entry) => entry.username === message.username);
        if (!match) { sendResponse({ok: true, existing: false, changed: false}); break; }
        const stored = await nativeRequest({action: "fill_login", url: message.url, entryId: match.id});
        sendResponse({ok: true, existing: true, changed: stored.password !== message.password});
        break;
      }
      case "FILL_LOGIN": sendResponse({ok: true, ...(await nativeRequest({action: "fill_login", url: message.url, entryId: message.entryId}))}); break;
      case "FILL_LOGIN_WITH_TOTP": {
        const tabId = sender.tab?.id;
        if (tabId == null) throw new Error("无法识别当前浏览器标签页");
        const login = await nativeRequest({action: "fill_login", url: message.url, entryId: message.entryId});
        const totp = await nativeRequest({action: "generate_totp", url: message.url, entryId: message.entryId});
        if (!totp.code) throw new Error("桌面端没有返回验证码");
        pendingTotps.set(tabId, {entryId: message.entryId, code: totp.code, expiresAt: Date.now() + PENDING_TOTP_TTL_MS});
        sendResponse({ok: true, username: login.username, password: login.password});
        break;
      }
      case "FILL_TOTP": sendResponse({ok: true, ...(await nativeRequest({action: "generate_totp", url: message.url, entryId: message.entryId}))}); break;
      case "GET_PENDING_TOTP": {
        const tabId = sender.tab?.id;
        const pending = tabId == null ? undefined : pendingTotps.get(tabId);
        if (!pending || pending.expiresAt <= Date.now()) {
          if (tabId != null) pendingTotps.delete(tabId);
          sendResponse({ok: true});
        } else sendResponse({ok: true, code: pending.code, entryId: pending.entryId});
        break;
      }
      case "CLEAR_PENDING_TOTP": {
        if (sender.tab?.id != null) pendingTotps.delete(sender.tab.id);
        sendResponse({ok: true});
        break;
      }
      case "FETCH_FAVICON": {
        const iconURL = new URL(message.iconUrl || "/favicon.ico", message.url || undefined);
        if (!/^https?:$/.test(iconURL.protocol)) throw new Error("网站图标地址无效");
        const response = await fetch(iconURL.href, {credentials: "omit"});
        if (!response.ok) throw new Error("网站图标加载失败");
        const mimeType = (response.headers.get("content-type") || "image/x-icon").split(";", 1)[0].trim().toLowerCase();
        if (!mimeType.startsWith("image/")) throw new Error("网站图标格式无效");
        const buffer = await response.arrayBuffer();
        if (buffer.byteLength > 256 * 1024) throw new Error("网站图标过大");
        const bytes = new Uint8Array(buffer); let binary = "";
        for (let offset = 0; offset < bytes.length; offset += 0x8000) binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
        sendResponse({ok: true, data: btoa(binary), mimeType});
        break;
      }
      case "SAVE_LOGIN": sendResponse({ok: true, ...(await nativeRequest({action: "save_login", url: message.url, name: message.name, username: message.username, password: message.password, faviconData: message.faviconData, faviconMimeType: message.faviconMimeType}))}); break;
      default: throw new Error("未知请求");
    }
  })().catch((error) => sendResponse({ok: false, error: error.message}));
  return true;
});
