// Service Worker for Web Push Notifications
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (event) { event.waitUntil(clients.claim()); });

self.addEventListener("push", function (event) {
  if (!event.data) return;

  let payload;
  try {
    payload = event.data.json();
  } catch (e) {
    payload = { title: "CodeMySpec", body: event.data.text() };
  }

  const title = payload.title || "CodeMySpec";
  const url = payload.url || "/app";

  const options = {
    body: payload.body || "",
    icon: "/images/logo.svg",
    badge: "/images/logo.svg",
    tag: payload.type || "default",
    data: { url: url },
    requireInteraction: payload.type === "permission_request",
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", function (event) {
  event.notification.close();

  const url = (event.notification.data && event.notification.data.url) || "/app";

  // Always open a new window/tab to the target URL.
  // LiveView navigation doesn't work reliably with client.navigate().
  event.waitUntil(clients.openWindow(url));
});
