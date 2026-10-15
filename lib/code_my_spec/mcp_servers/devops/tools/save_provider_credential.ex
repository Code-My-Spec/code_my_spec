defmodule CodeMySpec.McpServers.Devops.Tools.SaveProviderCredential do
  @moduledoc """
  Save one provider credential — a Hetzner, Cloudflare or Resend API key —
  on the agent's behalf.

  For the case `ProviderRequest`'s own "agent asks, server acts" shape
  doesn't cover: an agent that has *obtained* a credential (from the
  person it's working with, from a setup wizard elsewhere) and needs it on
  file before the provisioning steps that read it can run. The value is
  written straight through to `Credentials.put_value/3` — the same write
  the console's own credentials form makes — and never echoed back.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Activity
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning.Credentials

  schema do
    field :key, :string,
      required: true,
      description: "Catalogue key, e.g. \"hetzner_api_token\", \"cloudflare_api_token\", \"resend_api_key\"."

    field :value, :string, required: true, description: "The credential's value."
  end

  @impl true
  def execute(%{key: key, value: value} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, credential} <- fetch_credential(key),
         {:ok, _} <- Credentials.put_value(scope, credential, value) do
      Activity.record(scope, "credential_save", "credentials", "saved #{credential.label}",
        agent_id: frame.assigns[:agent_id]
      )

      {:reply, ok("#{credential.label} is on file."), frame}
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp fetch_credential(key) do
    case Enum.find(Credentials.catalogue(), &(&1.key == key)) do
      nil -> {:error, "unknown credential #{inspect(key)}"}
      credential -> {:ok, credential}
    end
  end

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not save the credential: #{inspect(reason)}")
end
