function visibleInputs() {
  return [...document.querySelectorAll("input")].filter((input) => { const style = getComputedStyle(input); return style.display !== "none" && style.visibility !== "hidden" && !input.disabled; });
}
function findFields() {
  const inputs = visibleInputs();
  const passwordInputs = inputs.filter((input) => input.type === "password");
  const password = passwordInputs[0];
  const username = inputs.find((input) => /user|email|login|account/i.test(`${input.name} ${input.id} ${input.autocomplete}`) && input.type !== "password") || inputs.find((input) => input.type === "email" || input.type === "text");
  const otp = inputs.find((input) => input.autocomplete === "one-time-code" || /otp|totp|2fa|mfa|auth|verification|security|code|token|安全码|验证码|动态密码|一次性/i.test(`${input.name} ${input.id} ${input.autocomplete} ${input.placeholder}`) && input.type !== "password");
  return {username, password, passwordCount: passwordInputs.length, otp};
}
function isLoginLikePage(fields) {
  if (fields.otp) return true;
  if (!fields.username && (!fields.password || fields.passwordCount !== 1)) return false;
  const hints = `${document.title} ${location.pathname} ${[...document.querySelectorAll("form, input, button")].slice(0, 80).map((element) => `${element.getAttribute("name") || ""} ${element.getAttribute("id") || ""} ${element.getAttribute("placeholder") || ""} ${element.textContent || ""}`).join(" ")}`;
  if (/settings|setting|profile|change-password|password-reset|账户设置|安全设置|修改密码|重置密码/i.test(hints)) return false;
  return /login|signin|sign-in|auth|用户名|登录|登陆|密码/i.test(hints);
}
function setValue(input, value) {
  if (!input) return false;
  input.focus({preventScroll: true});
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set?.call(input, value);
  input.dispatchEvent(new Event("input", {bubbles: true, composed: true}));
  input.dispatchEvent(new Event("change", {bubbles: true, composed: true}));
  return input.value === value;
}
async function fillLogin(entryId) { const response = await chrome.runtime.sendMessage({type: "FILL_LOGIN", url: location.href, entryId}); if (!response?.ok) throw new Error(response?.error || "填充失败"); const fields = findFields(); const usernameFilled = setValue(fields.username, response.username); const passwordFilled = setValue(fields.password, response.password); if (!(usernameFilled || passwordFilled)) throw new Error("没有找到可填充的登录字段"); }
function findContinueButton() {
  const candidates = [...document.querySelectorAll("button, input[type=submit], [role=button]")].filter((element) => {
    const style = getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden" && !element.disabled;
  });
  return candidates.find((element) => /^(下一步|继续|next|continue)$/i.test((element.innerText || element.value || element.textContent || "").trim()));
}
async function fillLoginWithTotp(entryId) {
  const response = await chrome.runtime.sendMessage({type: "FILL_LOGIN_WITH_TOTP", url: location.href, entryId});
  if (!response?.ok) throw new Error(response?.error || "Touch ID 登录失败");
  const fields = findFields();
  const usernameFilled = setValue(fields.username, response.username);
  const passwordFilled = setValue(fields.password, response.password);
  if (!(usernameFilled || passwordFilled)) throw new Error("没有找到可填充的登录字段");
  const nextButton = findContinueButton();
  if (nextButton) setTimeout(() => nextButton.click(), 80);
}
async function fillTotp(entryId) { const response = await chrome.runtime.sendMessage({type: "FILL_TOTP", url: location.href, entryId}); if (!response?.ok) throw new Error(response?.error || "验证码填充失败"); if (!setValue(findFields().otp, response.code)) throw new Error("没有找到验证码字段"); }
function styleButton(button) { button.style.cssText = "border:0;border-radius:7px;padding:6px 9px;cursor:pointer;background:#fff;color:#16202a;font:12px -apple-system,BlinkMacSystemFont,sans-serif"; }
let suppressFillPromptUntil = 0;
let savePromptPending = false;
function makePrompt(id, labelText, actions) {
  document.getElementById(id)?.remove(); const host = document.createElement("div"); host.id = id; host.style.cssText = "position:fixed;right:20px;bottom:20px;z-index:2147483647";
  const shadow = host.attachShadow({mode: "closed"});
  const box = document.createElement("div");
  box.style.cssText = "width:360px;max-width:calc(100vw - 36px);font:13px -apple-system,BlinkMacSystemFont,sans-serif;background:#fff;color:#182230;border:1px solid #dfe6f0;border-radius:14px;padding:14px;box-shadow:0 14px 38px rgba(18,38,63,.18),0 2px 8px rgba(18,38,63,.08);display:flex;flex-direction:column;gap:11px";
  const header = document.createElement("div"); header.style.cssText = "display:flex;align-items:flex-start;gap:9px";
  const mark = document.createElement("span"); mark.textContent = "✦"; mark.style.cssText = "width:25px;height:25px;flex:0 0 25px;border-radius:8px;display:grid;place-items:center;background:#e9f1ff;color:#2166d1;font-size:14px;font-weight:700";
  const heading = document.createElement("div"); heading.style.cssText = "min-width:0;flex:1;display:flex;flex-direction:column;gap:2px";
  const brand = document.createElement("strong"); brand.textContent = "Password Entry"; brand.style.cssText = "font-size:13px;line-height:18px;letter-spacing:-.1px";
  const label = document.createElement("span"); label.textContent = labelText; label.style.cssText = "color:#64748b;font-size:11px;line-height:16px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis";
  heading.append(brand, label);
  const close = document.createElement("button"); close.textContent = "×"; close.setAttribute("aria-label", "关闭"); close.style.cssText = "width:24px;height:24px;border:0;border-radius:7px;background:transparent;color:#718096;font-size:18px;line-height:20px;padding:0;cursor:pointer";
  close.addEventListener("mouseenter", () => { close.style.background = "#f1f5f9"; }); close.addEventListener("mouseleave", () => { close.style.background = "transparent"; });
  close.addEventListener("click", () => { suppressFillPromptUntil = Date.now() + 1500; host.remove(); });
  header.append(mark, heading, close); box.append(header);
  const actionList = document.createElement("div"); actionList.style.cssText = "display:flex;flex-direction:column;gap:7px";
  for (const action of actions) {
    const row = document.createElement("div");
    if (action.accountName || action.accountUsername) {
      row.style.cssText = "display:flex;align-items:center;gap:9px;padding:9px;border:1px solid #e6ebf2;border-radius:10px;background:#fbfcfe";
      const avatar = document.createElement("span"); avatar.textContent = [...(action.accountName || action.accountUsername || "?")].find((character) => /[\p{L}\p{N}]/u.test(character)) || "?"; avatar.style.cssText = "width:28px;height:28px;flex:0 0 28px;border-radius:50%;display:grid;place-items:center;background:#e8f1ff;color:#2166d1;font-size:12px;font-weight:700";
      const account = document.createElement("div"); account.style.cssText = "min-width:0;flex:1;display:flex;flex-direction:column;gap:2px";
      const name = document.createElement("strong"); name.textContent = action.accountName || "登录项"; name.style.cssText = "font-size:11px;line-height:15px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap";
      const username = document.createElement("span"); username.textContent = action.accountUsername || ""; username.style.cssText = "color:#718096;font-size:10px;line-height:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap";
      account.append(name, username);
      const button = document.createElement("button"); button.textContent = action.label; button.style.cssText = "border:0;border-radius:8px;padding:7px 10px;background:#2166d1;color:#fff;cursor:pointer;font:600 11px -apple-system,BlinkMacSystemFont,sans-serif;white-space:nowrap";
      button.addEventListener("mouseenter", () => { button.style.background = "#1854b4"; }); button.addEventListener("mouseleave", () => { button.style.background = "#2166d1"; });
      button.addEventListener("click", async () => { try { await action.run(); suppressFillPromptUntil = Date.now() + 1500; host.remove(); } catch (error) { label.textContent = error.message; } });
      row.append(avatar, account, button);
    } else {
      row.style.cssText = "display:flex;justify-content:flex-end";
      const button = document.createElement("button"); button.textContent = action.label; styleButton(button); button.style.cssText += ";background:#2166d1;color:#fff;font-weight:600";
      button.addEventListener("click", async () => { try { await action.run(); suppressFillPromptUntil = Date.now() + 1500; host.remove(); } catch (error) { label.textContent = error.message; } }); row.append(button);
    }
    actionList.append(row);
  }
  box.append(actionList); shadow.append(box); document.documentElement.appendChild(host); return host;
}
async function showFillPrompt() {
  const fields = findFields(); if (!isLoginLikePage(fields)) return;
  if (fields.otp && /^\d{6,8}$/.test(fields.otp.value || "")) return;
  const response = await chrome.runtime.sendMessage({type: "PAGE_HINT", url: location.href}); if (!response?.available) return;
  const entries = response.entries || [];
  const actions = entries.flatMap((entry) => {
    const account = entry.username || entry.name || "登录项";
    const entryActions = [];
    if (fields.username || fields.password) entryActions.push({label: entry.hasTotp ? "Touch ID 登录" : "填充登录", accountName: entry.name, accountUsername: account, run: entry.hasTotp ? () => fillLoginWithTotp(entry.id) : () => fillLogin(entry.id)});
    if (fields.otp && entry.hasTotp) entryActions.push({label: "填充验证码", accountName: entry.name, accountUsername: account, run: () => fillTotp(entry.id)});
    return entryActions;
  });
  if (actions.length) makePrompt("password-entry-fill-prompt", entries.length > 1 ? `匹配的登录项 · ${entries.length} 个账号` : (entries[0]?.name || "匹配的登录项"), actions);
}
function pageFaviconURL() {
  const link = document.querySelector('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]');
  try {
    const candidate = new URL(link?.href || "/favicon.ico", location.href);
    return /^https?:$/.test(candidate.protocol) ? candidate.href : new URL("/favicon.ico", location.href).href;
  } catch { return ""; }
}
async function showSavePrompt(username, password) {
  if (!username || !password || savePromptPending || document.getElementById("password-entry-save-prompt")) return;
  savePromptPending = true;
  try {
    const check = await chrome.runtime.sendMessage({type: "CHECK_LOGIN", url: location.href, username, password});
    if (check?.existing && !check.changed) return;
    const existing = Boolean(check?.existing);
    const promptText = existing ? "检测到密码已变化，是否更新此登录信息？" : "是否保存此登录信息？";
    const actionText = existing ? "更新登录" : "保存登录";
    makePrompt("password-entry-save-prompt", promptText, [{label: actionText, run: async () => {
      let favicon = {};
      try { favicon = await chrome.runtime.sendMessage({type: "FETCH_FAVICON", iconUrl: pageFaviconURL() }); } catch { /* credentials can still be saved without an icon */ }
      const response = await chrome.runtime.sendMessage({type: "SAVE_LOGIN", url: location.href, name: document.title || location.hostname, username, password, faviconData: favicon?.data, faviconMimeType: favicon?.mimeType});
      if (!response?.ok) throw new Error(response?.error || "保存失败");
    }}]);
  } finally {
    savePromptPending = false;
  }
}
function maybeSaveCurrentForm(form) {
  const fields = findFields();
  const scoped = form instanceof HTMLFormElement ? [...form.querySelectorAll("input")].filter((input) => input.offsetParent !== null) : [];
  const password = scoped.find((input) => input.type === "password") || fields.password;
  const username = scoped.find((input) => input !== password && (/user|email|login|account/i.test(`${input.name} ${input.id} ${input.autocomplete}`) || input.type === "email")) || fields.username;
  showSavePrompt(username?.value || "", password?.value || "").catch(() => {});
}
document.addEventListener("submit", (event) => maybeSaveCurrentForm(event.target), true);
document.addEventListener("click", (event) => {
  const button = event.target instanceof Element ? event.target.closest("button, input[type=submit], [role=button]") : null;
  if (!button) return;
  const form = button.closest("form");
  if (form) setTimeout(() => maybeSaveCurrentForm(form), 0);
}, true);
let pendingFillInProgress = false;
async function fillPendingTotp() {
  const input = findFields().otp;
  if (!input || /^\d{6,8}$/.test(input.value || "") || pendingFillInProgress) return false;
  pendingFillInProgress = true;
  try {
    const pending = await chrome.runtime.sendMessage({type: "GET_PENDING_TOTP"});
    if (!pending?.code || !setValue(input, pending.code)) return false;
    await new Promise((resolve) => setTimeout(resolve, 50));
    if (findFields().otp?.value !== pending.code) return false;
    await chrome.runtime.sendMessage({type: "CLEAR_PENDING_TOTP"});
    return true;
  } finally {
    pendingFillInProgress = false;
  }
}
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message.type === "FILL_LOGIN") {
    const fields = findFields();
    if (!fields.username && !fields.password) return true;
    const usernameFilled = setValue(fields.username, message.username);
    const passwordFilled = setValue(fields.password, message.password);
    sendResponse({ok: usernameFilled || passwordFilled, error: usernameFilled || passwordFilled ? undefined : "没有找到可填充的登录字段"});
  } else if (message.type === "FILL_TOTP") {
    const input = findFields().otp;
    if (!input) return true;
    const filled = setValue(input, message.code);
    sendResponse({ok: filled, error: filled ? undefined : "没有找到可填充的验证码字段"});
  } else if (message.type === "FILL_LOGIN_WITH_TOTP") {
    const fields = findFields();
    if (!fields.username && !fields.password) return true;
    fillLoginWithTotp(message.entryId).then(() => sendResponse({ok: true})).catch((error) => sendResponse({ok: false, error: error.message}));
  } else if (message.type === "GET_PAGE_FIELDS") {
    const fields = findFields();
    if (!fields.username && !fields.password && !fields.otp) return true;
    sendResponse({ok: true, hasLogin: Boolean(fields.username || fields.password), hasOtp: Boolean(fields.otp)});
  }
  return true;
});
let lastLocation = location.href;
const refreshPrompt = async () => { if (Date.now() < suppressFillPromptUntil) return; if (location.href !== lastLocation) { lastLocation = location.href; } if (await fillPendingTotp()) return; showFillPrompt().catch(() => {}); };
setTimeout(refreshPrompt, 700);
new MutationObserver(() => { if (!document.getElementById("password-entry-fill-prompt")) refreshPrompt(); }).observe(document.documentElement, {subtree: true, childList: true});
