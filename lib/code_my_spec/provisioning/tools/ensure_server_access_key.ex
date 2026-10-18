defmodule CodeMySpec.Provisioning.Tools.EnsureServerAccessKey do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Servers

  @impl true
  def name, do: "ensure_server_access_key"

  @impl true
  def description do
    """
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
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        scope
        |> Servers.access_public_key()
        |> reply()

      {:error, reason} ->
        error(reason)
    end
  end

  defp reply({:ok, public_key}) do
    text =
      "Account SSH public key (add this to any linked box's authorized_keys):\n\n#{public_key}"

    ok(text)
  end

  defp reply({:error, reason}), do: error(reason)

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not get the account's access key: #{inspect(reason)}"}
end
