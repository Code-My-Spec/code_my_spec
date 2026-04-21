defmodule CodeMySpecWeb.AppLive.Onboarding do
  use CodeMySpecWeb, :live_view

  def mount(_params, _session, socket) do
    just_confirmed = Phoenix.Flash.get(socket.assigns.flash, :info) == "User confirmed successfully."
    {:ok, assign(socket, page_title: "Welcome", just_confirmed: just_confirmed)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div
        id="onboarding-page"
        phx-hook=".SignUpTracking"
        data-just-confirmed={to_string(@just_confirmed)}
        class="max-w-2xl mx-auto px-6 py-16"
      >
        <h1 class="text-3xl font-heading font-bold mb-4">Welcome to CodeMySpec</h1>

        <p class="text-base-content/80 mb-10">
          Hey &mdash; I'm John. CodeMySpec drives Phoenix projects from user stories
          to working code through a requirement graph. Pick how you want to get started.
        </p>

        <div class="flex flex-col gap-6">
          <div class="bg-base-200 rounded-lg p-6 border border-primary/30">
            <div class="flex items-baseline justify-between mb-2 gap-3">
              <h2 class="text-xl font-heading font-semibold">
                Install the Claude Code extension
              </h2>
              <span class="badge badge-primary badge-sm shrink-0">Recommended</span>
            </div>
            <p class="text-sm text-base-content/70 mb-4">
              The full workflow &mdash; design, specs, tests, code, QA &mdash; plus a
              local admin UI and the Product Manager MCP, all bundled. Runs on port 4003.
            </p>
            <div class="mockup-code text-sm mb-4">
              <pre data-prefix="&gt;"><code>/plugin marketplace add Code-My-Spec/plugins</code></pre>
              <pre data-prefix="&gt;"><code>/plugin install codemyspec@codemyspec</code></pre>
            </div>
            <p class="text-sm text-base-content/70 mb-3">
              Then open
              <code class="text-primary">http://localhost:4003/auth</code>
              to sign in and link your first project.
            </p>
            <.link
              href={~p"/documentation/getting-started"}
              class="link link-primary text-sm"
            >
              Full walkthrough &rarr;
            </.link>
          </div>

          <div class="bg-base-200 rounded-lg p-5">
            <h3 class="font-heading font-semibold mb-2">Just want to draft stories?</h3>
            <p class="text-sm text-base-content/70 mb-3">
              Not on Claude Code? Point any MCP client at the remote Product Manager
              server. It interviews you and writes structured user stories.
            </p>
            <div class="mockup-code text-sm mb-3">
              <pre><code>Server URL: <%= CodeMySpecWeb.Endpoint.url() <> "/mcp/stories" %></code></pre>
            </div>
            <.link href={~p"/documentation/stories-mcp-setup"} class="link link-primary text-sm">
              Setup instructions &rarr;
            </.link>
          </div>

          <div class="flex items-center justify-between text-sm text-base-content/70 pt-2">
            <span>
              Rather talk it through?
              <a
                href="https://cal.com/john-s10-davenport"
                target="_blank"
                rel="noopener"
                class="link link-primary"
              >
                Book a call with John
              </a>
            </span>
            <.link navigate={~p"/app"} class="link">Skip &rarr;</.link>
          </div>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SignUpTracking">
        export default {
          mounted() {
            if (this.el.dataset.justConfirmed === "true" && typeof gtag === "function") {
              gtag("event", "sign_up");
            }
          }
        }
      </script>
    </Layouts.marketing>
    """
  end
end
