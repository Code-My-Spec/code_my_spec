defmodule CodeMySpecWeb.AppLive.Onboarding do
  use CodeMySpecWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Welcome")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div class="max-w-xl mx-auto px-6 py-16">
        <h1 class="text-3xl font-heading font-bold mb-6">Welcome to CodeMySpec</h1>

        <div class="text-base-content/80 space-y-3 mb-10">
          <p>
            Hey &mdash; I'm John. CodeMySpec is something I'm actively building.
            The methodology is real (I use it for client projects), but the tooling
            is early and moving fast.
          </p>
          <p>
            The quickest way to get value is to just talk to me. I'll help you get
            set up with the spec-driven workflow for your project.
          </p>
        </div>

        <div class="flex flex-col gap-5">
          <a
            href="https://cal.com/john-s10-davenport"
            target="_blank"
            rel="noopener"
            class="btn btn-primary btn-lg w-full"
          >
            Book a Call with John
          </a>

          <div class="divider text-base-content/40">or get started on your own</div>

          <div class="bg-base-200 rounded-lg p-5">
            <h3 class="font-heading font-semibold mb-2">Add the Product Manager</h3>
            <p class="text-sm text-base-content/70 mb-3">
              Point Claude Code, Cursor, or any MCP client at this server.
              It'll interview you about what you're building and write structured stories.
            </p>
            <div class="mockup-code text-sm mb-3">
              <pre><code>Server URL: <%= CodeMySpecWeb.Endpoint.url() <> "/mcp/stories" %></code></pre>
            </div>
            <.link href={~p"/pages/stories-mcp-server"} class="link link-primary text-sm">
              Full setup instructions &rarr;
            </.link>
          </div>

          <.link navigate={~p"/app"} class="btn btn-ghost w-full">
            Skip for now &mdash; explore the app
          </.link>
        </div>
      </div>
    </Layouts.marketing>
    """
  end
end
