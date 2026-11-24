"use strict";
const ports = {"Wi-Fi": 48771, "USB": 48772};
const selections = new Map();
let native;
let version = 0;

async function publish() {
  const tick = ++version;
  const windows = await browser.windows.getAll({windowTypes: ["normal"], populate: true});
  if (tick !== version || !native) return;
  native.postMessage({windows: windows.filter(w => !w.incognito).map(w => ({
    id: w.id, title: (w.tabs.find(t => t.active)?.title || "Firefox window").slice(0,160),
    route: selections.get(w.id)?.name || "Default"
  }))});
}

function clearRoute(id) {
  const previous = selections.get(id);
  if (previous) browser.proxy.onRequest.removeListener(previous.handler);
  selections.delete(id);
}

async function select({id, route}) {
  if (!Number.isInteger(id) || !(Object.hasOwn(ports, route) || route === "Default")) return;
  const target = await browser.windows.get(id);
  if (target.incognito || target.type !== "normal") return;
  clearRoute(id);
  if (route !== "Default") {
    const handler = () => ({type: "socks", host: "127.0.0.1", port: ports[route], proxyDNS: true});
    browser.proxy.onRequest.addListener(handler, {urls: ["<all_urls>"], windowId: id});
    selections.set(id, {name: route, handler});
  }
  await publish();
}

function connect() {
  native = browser.runtime.connectNative("local.web_routes.windows");
  native.onMessage.addListener(command => select(command).catch(() => publish()));
  native.onDisconnect.addListener(() => {
    native = null;
    setTimeout(connect, 3000);
  });
  publish();
}

browser.windows.onRemoved.addListener(id => { clearRoute(id); publish(); });
browser.windows.onCreated.addListener(publish);
browser.tabs.onActivated.addListener(publish);
browser.tabs.onUpdated.addListener((id, change) => { if (change.title) publish(); });
connect();
