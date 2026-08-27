defmodule CodeMySpec.McpServers.Devops.Tools.SetProvisioningCredential do
  @moduledoc """
  Store a pasted provisioning credential — a Hetzner API token, an object
  storage key pair — the same way the provisioning page's form does.

  This is the `kind: :secret` half of `Credentials.catalogue/0` only.
  `kind: :connection` credentials (Cloudflare, Resend, GitHub) are OAuth
  grants, not values an agent can hand over — there is nothing to paste, and
  attempting to store one here is refused by name rather than accepted and
  silently doing nothing.

  Verified the same way the page verifies a save: `Credentials.check/3` makes
  a real call after the value is stored, because a token that is the right
  shape and turns out read-only is a different, later failure than "invalid" —
  see `Credentials.catalogue/0`'s own moduledoc (criterion 7983/7984).
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning.Credentials

  schema do
    field :key, :string,
      required: true,
      doc:
        "A key from the provisioning credential catalogue, e.g. \"hetzner_api_token\" " <>
          "or \"hetzner_s3_access_key_id\". Only kind: :secret entries can be set here."

    field :value, :string, required: true, doc: "The credential value to store."
  end

  @impl true
  def execute(%{key: key, value: value}, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, %{}),
         {:ok, credential} <- find(key) do
      Credentials.put_value(scope, credential, String.trim(value))
      {:reply, ok(result(credential, Credentials.check(scope, credential))), frame}
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp find(key) do
    case Enum.find(Credentials.catalogue(), &(&1.key == key)) do
      nil ->
        {:error,
         "No credential named #{inspect(key)}. Known keys: " <>
           Enum.map_join(Credentials.catalogue(), ", ", & &1.key)}

      %{kind: :connection} = credential ->
        {:error,
         "#{credential.label} (#{key}) is an OAuth connection, not a pasted value — " <>
           "there is nothing to set here for it."}

      credential ->
        {:ok, credential}
    end
  end

  defp result(credential, :verified),
    do: "Saved and verified: #{credential.label} works."

  defp result(credential, :missing),
    do: "Saved #{credential.label}, but the check says it is still missing — the write may not have taken."

  defp result(credential, :unchecked),
    do:
      "Saved #{credential.label}. Could not verify it right now (the check itself raised) — " <>
        "call devops_status to see current state."

  defp result(credential, {:rejected, missing_permission}),
    do:
      "Saved #{credential.label}, but the provider rejected it: needs #{missing_permission}. " <>
        credential.directions

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason) when is_binary(reason),
    do: Response.tool() |> Response.error(reason)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not set credential: #{inspect(reason)}")
end
