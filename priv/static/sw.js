// Service Worker for Web Push Notifications
self.addEventListener("push", function (event) {
  if (!event.data) return;

  let payload;
  try {
    payload = event.data.json();
  } catch (e) {
    payload = { title: "CodeMySpec", body: event.data.text() };
  }

  const title = payload.title || "CodeMySpec";
  const options = {
    body: payload.body || "",
    icon: "/images/logo.svg",
    badge: "/images/logo.svg",
    tag: payload.type || "default",
    data: { type: payload.type, url: "/app" },
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", function (event) {
  event.notification.close();

  const url = (event.notification.data && event.notification.data.url) || "/app";

  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (clientList) {
      // Focus existing tab if found
      for (const client of clientList) {
        if (client.url.includes("/app") && "focus" in client) {
          return client.focus();
        }
      }
      // Otherwise open a new tab
      return clients.openWindow(url);
    })
  );
});
