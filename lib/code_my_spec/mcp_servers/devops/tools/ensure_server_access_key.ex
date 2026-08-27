defmodule CodeMySpec.McpServers.Devops.Tools.EnsureServerAccessKey do
  @moduledoc """
  The account's SSH public key, minted if it doesn't exist yet.

  For a box CodeMySpec creates itself, `Servers.access_key/1` uploads this
  key to the provider as part of creation and nothing else is needed. For a
  box the account already owned before linking it — the case this tool is
  for — there is no provider API that retrofits an SSH key onto an
  already-existing server. The account owner adds this text to that box's
  `authorized_keys` once, by hand; after that, every project's server step
  reaches it the same way it reaches a box CodeMySpec built from scratch.

  Only the public key is ever returned. The private half stays in
  `AccountSecrets` and never leaves the server.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Servers

  schema do
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame, params) do
      {:ok, scope} ->
        scope
        |> Servers.access_public_key()
        |> reply(frame)

      {:error, reason} ->
        {:reply, error(reason), frame}
    end
  end

  defp reply({:ok, public_key}, frame) do
    text =
      "Account SSH public key (add this to any linked box's authorized_keys):\n\n#{public_key}"

    {:reply, ok(text), frame}
  end

  defp reply({:error, reason}, frame), do: {:reply, error(reason), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not get the account's access key: #{inspect(reason)}")
end
