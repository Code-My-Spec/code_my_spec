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
        <.button data-test="close-secrets-modal" class="btn" patch={@return_to}>
          Close
        </.button>
      </div>
    </div>
    """
  end
end
