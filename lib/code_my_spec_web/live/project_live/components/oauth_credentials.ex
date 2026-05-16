defmodule CodeMySpecWeb.ProjectLive.Components.OauthCredentials do
  @moduledoc """
  Displays OAuth application credentials (client ID and secret) for a project.
  Secret is only visible at generation/regeneration time.
  """
  use CodeMySpecWeb, :html

  attr :project, :map, required: true
  attr :oauth_app, :map, default: nil
  attr :plaintext_secret, :string, default: nil

  def oauth_credentials(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300 mt-8">
      <div class="card-body">
        <h2 class="card-title">
          <.icon name="hero-key" class="size-6" /> OAuth Credentials
        </h2>
        <p class="text-base-content/70">
          Use these credentials to connect MCP clients or API integrations to this project.
        </p>

        <div :if={is_nil(@oauth_app)} class="mt-4">
          <button phx-click="generate_oauth_app" class="btn btn-primary">
            <.icon name="hero-plus-circle" class="size-5" /> Generate Credentials
          </button>
        </div>

        <div :if={@oauth_app} class="mt-4 space-y-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold">Client ID</span>
            </label>
            <div class="join w-full">
              <input
                type="text"
                value={@oauth_app.uid}
                readonly
                class="input input-bordered join-item flex-1 font-mono text-sm"
                id="oauth-client-id"
              />
              <button
                id="copy-client-id"
                type="button"
                data-to="#oauth-client-id"
                phx-hook="Copy"
                class="btn join-item"
                title="Copy"
              >
                <.icon name="hero-clipboard-document" class="size-4" />
              </button>
            </div>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold">Client Secret</span>
            </label>
            <div class="join w-full">
              <input
                :if={@plaintext_secret}
                type="text"
                value={@plaintext_secret}
                readonly
                class="input input-bordered join-item flex-1 font-mono text-sm"
                id="oauth-client-secret"
              />
              <input
                :if={is_nil(@plaintext_secret)}
                type="password"
                value="••••••••••••••••••••••••"
                readonly
                disabled
                class="input input-bordered join-item flex-1 font-mono text-sm opacity-50"
              />
              <button
                :if={@plaintext_secret}
                id="copy-client-secret"
                type="button"
                data-to="#oauth-client-secret"
                phx-hook="Copy"
                class="btn join-item"
                title="Copy"
              >
                <.icon name="hero-clipboard-document" class="size-4" />
              </button>
            </div>
            <p :if={@plaintext_secret} class="text-xs text-warning mt-1">
              Copy this secret now. It will not be shown again after you leave this page.
            </p>
            <p :if={is_nil(@plaintext_secret)} class="text-xs text-base-content/50 mt-1">
              Secret is hidden. Use "Regenerate Secret" to create a new one.
            </p>
          </div>

          <div class="flex gap-2 mt-4">
            <button
              type="button"
              phx-click={show_confirm("confirm-regenerate-oauth-secret")}
              class="btn btn-warning btn-sm"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Regenerate Secret
            </button>
            <button
              type="button"
              phx-click={show_confirm("confirm-delete-oauth-app")}
              class="btn btn-error btn-sm"
            >
              <.icon name="hero-trash" class="size-4" /> Delete Credentials
            </button>
            <.confirm_dialog
              id="confirm-regenerate-oauth-secret"
              title="Regenerate OAuth secret?"
              message="This will invalidate the current secret. Any clients using it will need to be updated."
              confirm_label="Regenerate"
              confirm_class="btn btn-warning"
              on_confirm={JS.push("regenerate_oauth_secret")}
            />
            <.confirm_dialog
              id="confirm-delete-oauth-app"
              title="Delete OAuth credentials?"
              message="This will permanently delete the OAuth credentials. Any connected clients will stop working."
              confirm_label="Delete"
              on_confirm={JS.push("delete_oauth_app")}
            />
          </div>
        </div>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          let { to } = this.el.dataset;
          this.el.addEventListener("click", (ev) => {
            ev.preventDefault();
            let text = document.querySelector(to).value;
            navigator.clipboard.writeText(text);
          });
        }
      }
    </script>
    """
  end
end
