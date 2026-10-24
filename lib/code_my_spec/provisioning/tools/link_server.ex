defmodule CodeMySpec.Provisioning.Tools.LinkServer do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Environments
  alias CodeMySpec.Resources
  alias CodeMySpec.Servers

  @impl true
  def name, do: "link_server"

  @impl true
  def description do
    """
    Point a project's environment at a server the account already owns.

    `environments` used to only ever get a server the setup step
    created for it — `server_name`/`ip` filled in as it went. An account-level
    server (`/app/servers`, story 879) can predate any project that ends up on
    it, or serve more than one at once, and nothing connected the two. This is
    that connection: once linked, the server step resolves this environment's
    box by the linked server's real name instead of deriving one from the
    project, so setup finds the box that's actually there rather than one that
    was never going to exist under a guessed name.

    Link the account's server first (`/app/servers`, or however it's linked)
    before calling this — it only points an environment at a server this
    account already has a record of.
    """
  end

  @impl true
  def params do
    %{
      server_name:
        {:required,
         {:meta, :string,
          [
            description:
              "Name of a server already linked to this account, e.g. \"fuellytics-prod\"."
          ]}},
      environment:
        {:required,
         {:meta, :string, [description: "Environment name, e.g. \"prod\" or \"uat\"."]}}
    }
  end

  @impl true
  def call(%{environment: environment, server_name: server_name}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope),
         scope <- Resources.project_scope(scope, project),
         {:ok, server} <- find_linked_server(scope, server_name) do
      scope
      |> Environments.put_deployment(environment, %{device_id: server.id})
      |> reply(environment, server_name, context)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp find_linked_server(scope, server_name) do
    case Servers.get_linked(scope, server_name) do
      nil ->
        {:error,
         "#{server_name} is not linked to this account yet — link it first, then point the environment at it"}

      server ->
        {:ok, server}
    end
  end

  defp reply({:ok, _environment}, environment, server_name, _context),
    do: ok("#{environment} now points at #{server_name}.")

  defp reply({:error, reason}, _environment, _server_name, _context), do: error(reason)

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not link the server: #{inspect(reason)}"}
end
