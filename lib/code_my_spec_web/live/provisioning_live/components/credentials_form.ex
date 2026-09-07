defmodule CodeMySpecWeb.ProvisioningLive.Components.CredentialsForm do
  @moduledoc """
  The provider-credentials form, factored out of `ProvisioningLive`'s render
  the same way `ServerLive.FormComponent` is factored out of `ServerLive.Index`
  — the form is its own module; the `<dialog>` that shows it lives on the
  page that opens it.

  All state (`@credentials`, `@missing_credentials`) and every event
  (`save_credentials`, `check_credentials`) still live on `ProvisioningLive`
  itself — this is a plain function component, not a `LiveComponent`, because
  nothing here needs state or a lifecycle of its own.
  """

  use CodeMySpecWeb, :html

  attr :return_to, :string, required: true
  attr :missing_credentials, :list, required: true
  attr :credentials, :list, required: true

  def credentials_form(assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-bold">Provider credentials</h3>
      <p class="opacity-70 text-sm mt-1">
        Everything this run needs, in one place. Hetzner has no OAuth — those are
        pasted and belong to this project. Cloudflare, Resend and GitHub are
        connected on <.link navigate={~p"/app/users/settings"} class="link">your account</.link>.
      </p>

      <div
        :if={@missing_credentials != []}
        data-test="credentials-incomplete"
        data-missing={Enum.map_join(@missing_credentials, ",", & &1.key)}
        class="alert alert-warning mt-3"
      >
        Setup cannot start yet — still needed: {Enum.map_join(
          @missing_credentials,
          ", ",
          & &1.label
        )}.
      </div>

      <form
        data-test="credentials-form"
        phx-submit="save_credentials"
        class="mt-3 flex flex-col gap-4"
      >
        <div
          :for={credential <- @credentials}
          data-test="credential-field"
          data-credential={credential.key}
          data-credential-kind={to_string(credential.kind)}
          data-stored={to_string(credential.stored?)}
          data-state={credential.state}
          class="flex flex-col gap-1"
        >
          <label class="label" for={credential.key}>
            <span class="label-text">{credential.label}</span>
            <span
              data-test="credential-state"
              data-key={credential.key}
              data-set={to_string(credential.stored?)}
              class={[
                "badge badge-sm",
                credential.state == "verified" && "badge-success",
                credential.state == "rejected" && "badge-error"
              ]}
            >
              {credential_badge(credential)}
            </span>
          </label>

          <input
            :if={credential.kind == :secret}
            type="password"
            id={credential.key}
            name={"credentials[#{credential.key}]"}
            data-test="credential-input"
            class="input input-bordered w-full"
            autocomplete="off"
            placeholder={
              if credential.stored?, do: "•••••••• (leave blank to keep)", else: credential.hint
            }
          />

          <p
            :if={credential.state == "rejected"}
            data-test="credential-rejection"
            data-credential={credential.key}
            class="text-xs text-error"
          >
            Rejected by the provider. Missing: {credential.missing_permission}
          </p>

          <p
            data-test="credential-directions"
            data-credential={credential.key}
            class="text-xs opacity-70"
          >
            {credential.directions}
          </p>

          <p class="text-xs opacity-50">{credential.why}</p>
        </div>

        <div class="modal-action">
          <.button data-test="close-credentials-modal" class="btn" patch={@return_to}>
            Close
          </.button>
          <.button type="button" data-test="check-credentials" phx-click="check_credentials">
            Check them against the providers
          </.button>
          <.button type="submit" class="btn btn-primary" data-test="save-credentials">
            Save credentials
          </.button>
        </div>
      </form>
    </div>
    """
  end

  # Never "not set" for a connection — Sam does not paste those, and telling
  # him a thing he connected on his account is unset sends him looking for a
  # field that is not there.
  defp credential_badge(%{state: "verified"}), do: "verified"
  defp credential_badge(%{state: "rejected"}), do: "rejected"
  defp credential_badge(%{stored?: true}), do: "set"
  defp credential_badge(%{kind: :connection}), do: "not connected"
  defp credential_badge(_), do: "not set"
end
