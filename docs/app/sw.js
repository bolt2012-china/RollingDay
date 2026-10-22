/* RollingDay PWA service worker — bump CACHE when shell changes */
const CACHE = "rollingday-pwa-v5";
const DB_NAME = "rollingday-reminders";
const DB_STORE = "pending";
const SHELL = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/apple-touch-icon.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  const isHtml = req.mode === "navigate" || url.pathname.endsWith("/") || url.pathname.endsWith(".html");
  if (isHtml) {
    // Network-first so fixes reach users; fall back to cache offline
    event.respondWith(
      fetch(req).then((res) => {
        if (res && res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
        return res;
      }).catch(() => caches.match(req).then((r) => r || caches.match("./index.html")))
    );
    return;
  }
  event.respondWith(
    caches.match(req).then((cached) => {
      const network = fetch(req).then((res) => {
        if (res && res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
        return res;
      }).catch(() => cached);
      return cached || network;
    })
  );
});

function openDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(DB_STORE)) {
        db.createObjectStore(DB_STORE, { keyPath: "id" });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function putReminder(row) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(DB_STORE, "readwrite");
    tx.objectStore(DB_STORE).put(row);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function deleteReminder(id) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(DB_STORE, "readwrite");
    tx.objectStore(DB_STORE).delete(id);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function allReminders() {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(DB_STORE, "readonly");
    const req = tx.objectStore(DB_STORE).getAll();
    req.onsuccess = () => resolve(req.result || []);
    req.onerror = () => reject(req.error);
  });
}

async function clearReminders() {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(DB_STORE, "readwrite");
    tx.objectStore(DB_STORE).clear();
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

const supportsTrigger = () => {
  try {
    return "showTrigger" in Notification.prototype && typeof TimestampTrigger === "function";
  } catch (e) {
    return false;
  }
};

async function scheduleOne(row) {
  await putReminder(row);
  const tag = "rd-" + row.id;
  try {
    const existing = await self.registration.getNotifications({ tag });
    for (const n of existing) n.close();
  } catch (e) {}

  if (row.fireAt <= Date.now()) return;

  if (supportsTrigger()) {
    try {
      await self.registration.showNotification(row.title || "滚滚日程提醒", {
        body: row.body || "日程即将开始",
        tag,
        icon: "./icons/icon-192.png",
        badge: "./icons/icon-192.png",
        data: { itemId: row.id, url: "./" },
        showTrigger: new TimestampTrigger(row.fireAt)
      });
      return { ok: true, mode: "trigger" };
    } catch (e) {
      return { ok: false, mode: "trigger-fail", error: String(e && e.message || e) };
    }
  }
  return { ok: true, mode: "idb-fallback" };
}

async function cancelOne(id) {
  await deleteReminder(id);
  try {
    const existing = await self.registration.getNotifications({ tag: "rd-" + id });
    for (const n of existing) n.close();
  } catch (e) {}
}

async function fireDue(maxMissedMs) {
  const now = Date.now();
  const rows = await allReminders();
  const fired = [];
  for (const row of rows) {
    if (!row || row.fired) continue;
    if (row.fireAt > now) continue;
    // Only show if within recent miss window, or just due
    if (now - row.fireAt > maxMissedMs) {
      await deleteReminder(row.id);
      continue;
    }
    const tag = "rd-" + row.id;
    try {
      await self.registration.showNotification(row.title || "滚滚日程提醒", {
        body: row.body || "日程即将开始（补发）",
        tag,
        icon: "./icons/icon-192.png",
        badge: "./icons/icon-192.png",
        data: { itemId: row.id, url: "./" }
      });
      fired.push(row.id);
    } catch (e) {}
    await deleteReminder(row.id);
  }
  return fired;
}

self.addEventListener("message", (event) => {
  const data = event.data || {};
  const reply = (payload) => {
    if (event.ports && event.ports[0]) event.ports[0].postMessage(payload);
  };

  event.waitUntil(
    (async () => {
      try {
        if (data.type === "schedule-reminder") {
          const result = await scheduleOne(data.reminder);
          reply(Object.assign({ type: "schedule-result", id: data.reminder && data.reminder.id }, result || {}));
        } else if (data.type === "cancel-reminder") {
          await cancelOne(data.id);
          reply({ type: "cancel-result", id: data.id, ok: true });
        } else if (data.type === "sync-reminders") {
          await clearReminders();
          const list = Array.isArray(data.reminders) ? data.reminders : [];
          const modes = [];
          for (const row of list) {
            modes.push(await scheduleOne(row));
          }
          reply({ type: "sync-result", ok: true, count: list.length, modes });
        } else if (data.type === "check-due") {
          const fired = await fireDue(data.maxMissedMs || 30 * 60 * 1000);
          reply({ type: "check-result", fired });
        } else if (data.type === "supports-trigger") {
          reply({ type: "supports-trigger", ok: supportsTrigger() });
        } else {
          reply({ type: "noop" });
        }
      } catch (e) {
        reply({ type: "error", error: String(e && e.message || e) });
      }
    })()
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || "./";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if ("focus" in client) {
          client.postMessage({ type: "notification-click", itemId: event.notification.data && event.notification.data.itemId });
          return client.focus();
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(target);
    })
  );
});

// Lightweight periodic due-check while SW is alive
setInterval(() => {
  try { if (self.indexedDB) fireDue(2 * 60 * 1000).catch(() => {}); } catch (e) {}
}, 60000);
