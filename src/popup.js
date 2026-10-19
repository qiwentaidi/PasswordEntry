const $ = (id) => document.getElementById(id);

let tab;
let pageContext = {hasLogin: false, hasOtp: false};
let rendering = false;
let syncTimer;

function showMessage(message, good = false) {
  $("message").textContent = message || "";
  $("message").style.color = good ? "#137333" : "#b42318";
}

function setStatus(kind, label, detail) {
  const badge = $("statusBadge");
  badge.className = `status-badge status-${kind}`;
  badge.querySelector("span").textContent = label;
  $("statusText").textContent = detail;
}

function setView(view) {
  $("offlineView").classList.toggle("hidden", view !== "offline");
  $("lockedView").classList.toggle("hidden", view !== "locked");
  $("readyView").classList.toggle("hidden", view !== "ready");
}

async function request(type, payload = {}) {
  const response = await chrome.runtime.sendMessage({ type, ...payload });
  if (!response?.ok) throw new Error(response?.error || "操作失败");
  return response;
}

async function activeTab() {
  return (await chrome.tabs.query({ active: true, currentWindow: true }))[0];
}

function renderSiteIcon(iconURL) {
  const container = $("siteIcon");
  container.replaceChildren();
  if (!iconURL) {
    container.textContent = "◎";
    return;
  }
  const image = document.createElement("img");
  image.alt = "";
  image.src = iconURL;
  image.addEventListener("error", () => { container.textContent = "◎"; }, { once: true });
  container.appendChild(image);
}

function renderEntry(entry) {
  const card = document.createElement("article");
  card.className = "entry";
  const actionMarkup = entry.hasTotp && pageContext.hasLogin
    ? '<button data-action="mfa-login">Touch ID 登录</button>'
    : entry.hasTotp && pageContext.hasOtp
      ? '<button data-action="totp">Touch ID 填验证码</button>'
      : `<button data-action="login">填充登录</button>${entry.hasTotp ? '<button data-action="totp">Touch ID 填验证码</button>' : ""}`;
  card.innerHTML = `<div class="entry-heading"><div class="entry-icon"></div><div><div class="entry-title"></div><div class="entry-site"></div><div class="entry-user"></div></div></div><div class="actions">${actionMarkup}</div>`;

  const icon = card.querySelector(".entry-icon");
  if (entry.faviconData) {
    const image = document.createElement("img");
    image.alt = "";
    image.src = `data:${entry.faviconMimeType || "image/png"};base64,${entry.faviconData}`;
    icon.appendChild(image);
  } else {
    icon.textContent = "◉";
  }
  card.querySelector(".entry-title").textContent = entry.name;
  card.querySelector(".entry-site").textContent = (entry.origins?.length ? entry.origins : entry.domains || []).join(", ");
  card.querySelector(".entry-user").textContent = entry.username;
  card.querySelectorAll("button").forEach((button) => button.addEventListener("click", async () => {
    try {
      const action = button.dataset.action;
      if (action === "mfa-login") {
        const fillResult = await chrome.tabs.sendMessage(tab.id, {type: "FILL_LOGIN_WITH_TOTP", url: tab.url, entryId: entry.id});
        if (!fillResult?.ok) throw new Error(fillResult?.error || "Touch ID 登录失败");
        showMessage("Touch ID 验证成功，正在填充登录信息", true);
        return;
      }
      const type = action === "login" ? "FILL_LOGIN" : "FILL_TOTP";
      const response = await request(type, { url: tab.url, entryId: entry.id });
      const fillResult = await chrome.tabs.sendMessage(tab.id, { type, ...response });
      if (!fillResult?.ok) {
        throw new Error(fillResult?.error || (type === "FILL_TOTP" ? "没有找到可填充的验证码字段" : "没有找到可填充的登录字段"));
      }
      showMessage(type === "FILL_TOTP" ? "验证码已填入" : "登录信息已填入", true);
    } catch (error) {
      showMessage(error.message);
    }
  }));
  return card;
}

async function render({ silent = false } = {}) {
  if (rendering) return;
  rendering = true;
  try {
    tab = await activeTab();
    const state = await request("GET_STATE");
    if (!state.running) {
      setStatus("offline", "未运行", "桌面端未运行");
      setView("offline");
      return;
    }
    if (!state.unlocked) {
      setStatus("locked", "已锁定", "请在桌面端输入主密码");
      setView("locked");
      return;
    }

    setStatus("ready", "已连接", "桌面端已解锁");
    setView("ready");
    const pageURL = tab?.url || "";
    if (!/^https?:/.test(pageURL)) {
      $("siteName").textContent = "当前页面";
      $("siteUrl").textContent = "此页面不支持登录填充";
      renderSiteIcon("");
      $("entryCount").textContent = "0";
      $("entries").replaceChildren();
      $("noMatchView").classList.remove("hidden");
      return;
    }

    const parsedURL = new URL(pageURL);
    $("siteName").textContent = parsedURL.hostname;
    $("siteUrl").textContent = parsedURL.origin;
    renderSiteIcon(tab.favIconUrl || `${parsedURL.origin}/favicon.ico`);
    pageContext = await chrome.tabs.sendMessage(tab.id, {type: "GET_PAGE_FIELDS"}).catch(() => ({hasLogin: false, hasOtp: false}));

    let response;
    try {
      response = await request("LIST_MATCHES", { url: pageURL });
    } catch (error) {
      if (!error.message.includes("没有匹配")) throw error;
      response = { entries: [] };
    }
    const entries = response.entries || [];
    $("entryCount").textContent = String(entries.length);
    $("entries").replaceChildren(...entries.map(renderEntry));
    $("noMatchView").classList.toggle("hidden", entries.length > 0);
  } catch (error) {
    setStatus("offline", "同步失败", "无法读取桌面端状态");
    if (!silent) showMessage(error.message);
  } finally {
    rendering = false;
  }
}

$("refreshButton").addEventListener("click", () => render().catch((error) => showMessage(error.message)));
setStatus("connecting", "连接中", "正在连接桌面端");
render().catch((error) => showMessage(error.message));
syncTimer = setInterval(() => render({ silent: true }), 2000);
window.addEventListener("unload", () => clearInterval(syncTimer));
