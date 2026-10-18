defmodule CodeMySpecWeb.ProvisioningLive.Components.SecretsForm do
  @moduledoc """
  The secrets form, factored out of `ProvisioningLive`'s render the same way
  `ServerLive.FormComponent` is factored out of `ServerLive.Index` — the form
  is its own module; the `<dialog>` that shows it lives on the page that
  opens it.

  All state (`@environments`, `@secret_error`, `@sops_recipients`,
  `@secret_sources`) and the `put_secret` event still live on
  `ProvisioningLive` — this is a plain function component, not a
  `LiveComponent`, because nothing here needs state or a lifecycle of its
  own.
  """

  use CodeMySpecWeb, :html

  attr :return_to, :string, required: true
  attr :environments, :list, required: true
  attr :secret_error, :string, default: nil
  attr :sops_recipients, :list, required: true
  attr :secret_sources, :list, required: true
  # False when embedded as a full page (the console) rather than a modal
  # (the old provisioning page) — "Close" means nothing on a page with its
  # own sidebar nav.
  attr :show_close?, :boolean, default: true

  def secrets_form(assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-bold">Secrets</h3>
      <p class="opacity-70 text-sm mt-1">
        Set once, encrypted into the repo. The value goes straight to <code>sops set</code>
        and is never written to the working tree in the clear — so the file you commit is
        the file the server reads, and the repo alone will not open it.
      </p>

      <form
        data-test="secret-form"
        phx-submit="put_secret"
        class="mt-3 flex flex-wrap gap-2 items-end"
      >
        <label class="form-control">
          <span class="label-text text-xs">Key</span>
          <input
            type="text"
            name="secret[key]"
            class="input input-bordered input-sm"
            placeholder="RESEND_API_KEY"
          />
        </label>
        <label class="form-control">
          <span class="label-text text-xs">Value</span>
          <input
            type="password"
            name="secret[value]"
            class="input input-bordered input-sm"
            autocomplete="off"
          />
        </label>
        <label class="form-control">
          <span class="label-text text-xs">Environment</span>
          <select name="secret[environment]" class="select select-bordered select-sm">
            <option :for={environment <- @environments} value={environment}>{environment}</option>
          </select>
        </label>
        <.button type="submit" data-test="save-secret">Encrypt into the repo</.button>
      </form>

      <p :if={@secret_error} data-test="secret-error" class="text-error text-xs mt-2">
        {@secret_error}
      </p>

      <div class="divider"></div>
      <h4 class="font-semibold text-sm">Bulk import</h4>
      <p class="opacity-70 text-xs mt-1">
        Already has its own secrets, like <code>SECRET_KEY_BASE</code> from a live app?
        Paste them here, one <code>KEY=value</code> per line -- comments and blank lines
        are skipped. Nothing here is minted fresh over a key that already exists, so
        importing an existing <code>SECRET_KEY_BASE</code> first keeps every signed-in
        user's session valid.
      </p>
      <form
        data-test="secrets-import-form"
        phx-submit="import_secrets"
        class="mt-2 flex flex-col gap-2 items-start"
      >
        <textarea
          name="import[dotenv]"
          data-test="secrets-import-dotenv"
          class="textarea textarea-bordered textarea-sm font-mono w-full"
          rows="6"
          placeholder="SECRET_KEY_BASE=...\nOTHER_KEY=..."
        ></textarea>
        <label class="form-control w-40">
          <span class="label-text text-xs">Environment</span>
          <select name="import[environment]" class="select select-bordered select-sm">
            <option :for={environment <- @environments} value={environment}>{environment}</option>
          </select>
        </label>
        <.button type="submit" data-test="import-secrets">Import into the repo</.button>
      </form>

      <div class="mt-4 flex flex-col gap-1">
        <div
          :for={recipient <- @sops_recipients}
          data-test="sops-recipient"
          data-environment={recipient.environment}
          data-key-fingerprint={List.first(recipient.fingerprints)}
          class="text-xs font-mono opacity-70"
        >
          {recipient.environment}: {Enum.join(recipient.fingerprints, ", ")}
        </div>
      </div>

      <div class="mt-4 flex flex-col gap-1">
        <div
          :for={source <- @secret_sources}
          data-test="secret-source"
          data-consumer={source.consumer}
          data-path={source.path}
          class="text-xs font-mono opacity-70"
        >
          {source.consumer} reads {source.path}
        </div>
      </div>

      <div class="modal-action">
        <.button :if={@show_close?} data-test="close-secrets-modal" class="btn" patch={@return_to}>
          Close
        </.button>
      </div>
    </div>
    """
  end
end
