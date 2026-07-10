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

  // Blocking prompts (approvals, questions) must persist until tapped and must
  // not replace one another — key their tag by URL so each stays its own.
  const blocking =
    payload.type === "permission_request" || payload.type === "question_request";

  const options = {
    body: payload.body || "",
    icon: "/images/logo.svg",
    badge: "/images/logo.svg",
    tag: blocking ? url : payload.type || "default",
    data: { url: url },
    requireInteraction: blocking,
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
