defmodule CodeMySpec.McpServers.Bootstrap.Tools.InitProject do
  @moduledoc """
  Initialize .code_my_spec/config.yml for the given project.

  Requires authentication. Fetches project details from the server and
  writes the local config file that links this working directory to the
  remote project.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.McpServers.Bootstrap.BootstrapMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :project_id, :string,
      required: true,
      doc: "UUID of the project to initialize (from list_projects)"
  end

  @impl true
  def execute(%{project_id: project_id}, frame) do
    working_dir = Validators.mcp_working_dir(frame)

    with {:ok, token} <- OAuthClient.get_token(),
         {:ok, projects} <- fetch_projects(token),
         {:ok, project} <- find_project(projects, project_id),
         {:ok, config_path, project_name} <- write_project_config(working_dir, project) do
      {:reply, BootstrapMapper.init_success(config_path, project_name), frame}
    else
      {:error, reason} ->
        {:reply, BootstrapMapper.error(reason), frame}
    end
  end

  defp fetch_projects(token) do
    server_url = OAuthClient.get_server_url()
    url = "#{server_url}/api/projects"
    headers = [{"authorization", "Bearer #{token}"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: %{"projects" => projects}}} -> {:ok, projects}
      {:ok, %{status: status}} -> {:error, "Server returned #{status}"}
      {:error, reason} -> {:error, "Failed to reach server: #{inspect(reason)}"}
    end
  end

  defp find_project(projects, project_id) do
    case Enum.find(projects, &(&1["id"] == project_id)) do
      nil -> {:error, "Project not found: #{project_id}"}
      project -> {:ok, project}
    end
  end

  defp write_project_config(working_dir, project) do
    app_name = detect_app_name(working_dir) || "my_app"
    module_name = Macro.camelize(app_name)

    config = %{
      "project_id" => project["id"],
      "account_id" => project["account_id"],
      "module_name" => project["module_name"] || module_name,
      "name" => project["name"],
      "description" => project["description"],
      "code_repo" => project["code_repo"],
      "docs_repo" => project["docs_repo"],
      "client_api_url" => project["client_api_url"]
    }

    config_dir = Path.join(working_dir, ".code_my_spec")
    config_path = Path.join(config_dir, "config.yml")

    File.mkdir_p!(config_dir)

    yaml =
      config
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join("\n", fn {key, value} -> format_yaml_entry(key, value) end)
      |> Kernel.<>("\n")

    case File.write(config_path, yaml) do
      :ok -> {:ok, config_path, project["name"]}
      {:error, reason} -> {:error, "Failed to write config: #{inspect(reason)}"}
    end
  end

  defp detect_app_name(working_dir) do
    mix_exs = Path.join(working_dir, "mix.exs")

    with true <- File.exists?(mix_exs),
         {:ok, content} <- File.read(mix_exs),
         [_, app_name] <- Regex.run(~r/app:\s*:(\w+)/, content) do
      app_name
    else
      _ -> nil
    end
  end

  defp format_yaml_entry(key, value) when is_list(value) do
    items = Enum.map_join(value, "\n", fn item -> "  - #{format_yaml_value(item)}" end)
    "#{key}:\n#{items}"
  end

  defp format_yaml_entry(key, value) do
    "#{key}: #{format_yaml_value(value)}"
  end

  defp format_yaml_value(value) when is_binary(value) do
    if String.contains?(value, [":", "@"]) do
      "\"#{value}\""
    else
      value
    end
  end

  defp format_yaml_value(value), do: value
end
