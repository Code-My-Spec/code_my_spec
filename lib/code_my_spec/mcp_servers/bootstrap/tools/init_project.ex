defmodule CodeMySpec.McpServers.Bootstrap.Tools.InitProject do
  @moduledoc """
  Link this working directory to a CodeMySpec project.

  Fetches project details from the server and creates/updates the local
  database record with `local_path` set to the working directory.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.McpServers.Bootstrap.BootstrapMapper
  alias CodeMySpec.McpServers.Bootstrap.Content
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Paths
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo

  schema do
    field :project_id, :string,
      required: true,
      doc: "UUID of the project to link (from list_projects)"
  end

  @impl true
  def execute(%{project_id: project_id}, frame) do
    working_dir = Validators.mcp_working_dir(frame)

    with {:ok, token} <- OAuthClient.get_token(),
         {:ok, project_data} <- fetch_project(token, project_id),
         {:ok, project} <- upsert_local_project(project_data, working_dir) do
      seed_infrastructure_paths(working_dir, project.module_name)
      {:reply, BootstrapMapper.init_success("local_path: #{working_dir}", project.name), frame}
    else
      {:error, reason} when reason in [:not_authenticated, :needs_authentication] ->
        {:reply, BootstrapMapper.not_authenticated_error(), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("#{reason}"), frame}
    end
  end

  # Seed `.code_my_spec/config.yml` with the canonical `infrastructure_paths`
  # list on first init. Idempotent — never overwrites an existing config.
  # The list mirrors `mix phx.new` output; users can edit the file to add
  # generated/auth/integration modules later.
  defp seed_infrastructure_paths(_working_dir, nil), do: :ok

  defp seed_infrastructure_paths(working_dir, module_name) do
    config_path = Path.join([working_dir, Paths.base_dir(), "config.yml"])

    if File.exists?(config_path) do
      :ok
    else
      File.mkdir_p!(Path.dirname(config_path))
      File.write!(config_path, Content.infrastructure_paths_yaml(module_name))
    end
  end

  defp fetch_project(token, project_id) do
    server_url = OAuthClient.get_server_url()
    url = "#{server_url}/api/projects"
    headers = [{"authorization", "Bearer #{token}"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: %{"projects" => projects}}} ->
        case Enum.find(projects, &(&1["id"] == project_id)) do
          nil -> {:error, "Project not found: #{project_id}"}
          project -> {:ok, project}
        end

      {:ok, %{status: status}} ->
        {:error, "Server returned #{status}"}

      {:error, reason} ->
        {:error, "Failed to reach server: #{inspect(reason)}"}
    end
  end

  defp upsert_local_project(server_data, working_dir) do
    client_user_id =
      case OAuthClient.get_active_client_user() do
        {:ok, %{id: id}} -> id
        _ -> nil
      end

    attrs = %{
      id: server_data["id"],
      name: server_data["name"],
      description: server_data["description"],
      module_name: server_data["module_name"],
      code_repo: server_data["code_repo"],
      docs_repo: server_data["docs_repo"],
      client_api_url: server_data["client_api_url"],
      account_id: server_data["account_id"],
      local_path: working_dir,
      client_user_id: client_user_id,
      status: :created
    }

    %Project{}
    |> Project.bootstrap_changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :name,
           :description,
           :module_name,
           :code_repo,
           :docs_repo,
           :client_api_url,
           :local_path,
           :client_user_id
         ]},
      conflict_target: :id,
      returning: true
    )
  end
end
