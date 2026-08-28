defmodule CodeMySpec.McpServers.Devops.Tools.LinkServer do
  @moduledoc """
  Point a project's environment at a server the account already owns.

  `provisioning_environments` used to only ever get a server the setup step
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

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.Resources
  alias CodeMySpec.Servers

  schema do
    field :environment, :string,
      required: true,
      doc: "Environment name, e.g. \"prod\" or \"uat\"."

    field :server_name, :string,
      required: true,
      doc: "Name of a server already linked to this account, e.g. \"fuellytics-prod\"."
  end

  @impl true
  def execute(%{environment: environment, server_name: server_name} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- Validators.devops_project(scope),
         scope <- Resources.project_scope(scope, project),
         {:ok, server} <- find_linked_server(scope, server_name) do
      scope
      |> EnvironmentRepository.put(environment, %{server_id: server.id})
      |> reply(environment, server_name, frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
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

  defp reply({:ok, _environment}, environment, server_name, frame),
    do: {:reply, ok("#{environment} now points at #{server_name}."), frame}

  defp reply({:error, reason}, _environment, _server_name, frame), do: {:reply, error(reason), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not link the server: #{inspect(reason)}")
end
