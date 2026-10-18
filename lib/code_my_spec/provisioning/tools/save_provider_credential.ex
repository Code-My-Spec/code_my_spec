defmodule CodeMySpec.Provisioning.Tools.SaveProviderCredential do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Activity
  alias CodeMySpec.Provisioning.Credentials

  @impl true
  def name, do: "save_provider_credential"

  @impl true
  def description do
    """
    Save one provider credential — a Hetzner, Cloudflare or Resend API key —
    on the agent's behalf.

    For the case `ProviderRequest`'s own "agent asks, server acts" shape
    doesn't cover: an agent that has *obtained* a credential (from the
    person it's working with, from a setup wizard elsewhere) and needs it on
    file before the provisioning steps that read it can run. The value is
    written straight through to `Credentials.put_value/3` — the same write
    the console's own credentials form makes — and never echoed back.
    """
  end

  @impl true
  def params do
    %{
      value: {:required, {:meta, :string, [description: "The credential's value."]}},
      key:
        {:required,
         {:meta, :string,
          [
            description:
              "Catalogue key, e.g. \"hetzner_api_token\", \"cloudflare_api_token\", \"resend_api_key\"."
          ]}}
    }
  end

  @impl true
  def call(%{key: key, value: value}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, credential} <- fetch_credential(key),
         {:ok, _} <- Credentials.put_value(scope, credential, value) do
      Activity.record(scope, "credential_save", "credentials", "saved #{credential.label}",
        agent_id: context[:agent_id]
      )

      ok("#{credential.label} is on file.")
    else
      {:error, reason} -> error(reason)
    end
  end

  defp fetch_credential(key) do
    case Enum.find(Credentials.catalogue(), &(&1.key == key)) do
      nil -> {:error, "unknown credential #{inspect(key)}"}
      credential -> {:ok, credential}
    end
  end

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not save the credential: #{inspect(reason)}"}
end
