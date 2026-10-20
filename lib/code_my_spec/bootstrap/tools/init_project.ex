defmodule CodeMySpec.Bootstrap.Tools.InitProject do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Environments
  alias CodeMySpec.Bootstrap.Tools.Installers
  alias CodeMySpec.Bootstrap.Tools.Responses, as: BootstrapMapper
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo

  @impl true
  def name, do: "init_project"

  @impl true
  def description do
    """
    Link this working directory to a CodeMySpec project.

    Fetches project details from the server and creates/updates the local
    database record with `local_path` set to the working directory.
    """
  end

  @impl true
  def params do
    %{
      project_id:
        {:required,
         {:meta, :string, [description: "UUID of the project to link (from list_projects)"]}}
    }
  end

  @impl true
  def call(%{project_id: project_id}, context) do
    case context[:working_dir] || CodeMySpec.WorkingCopies.configured_working_dir() do
      nil ->
        BootstrapMapper.error(CodeMySpec.Tools.no_working_copy_message("init_project"))

      working_dir ->
        link(project_id, working_dir, context)
    end
  end

  defp link(project_id, working_dir, context) do
    with {:ok, token} <- OAuthClient.get_token(),
         {:ok, project_data} <- fetch_project(token, project_id),
         {:ok, project} <- upsert_local_project(project_data, working_dir) do
      # Install the harness files the project needs but that require no
      # judgement — AGENTS.md, CLAUDE.md, rules, credo checks. Doing it here
      # rather than waiting for an agent to call four MCP tools is what lets a
      # freshly generated project satisfy `project_setup` with zero model
      # turns. Best-effort: a failed install must not fail the link.
      env = CodeMySpec.WorkingCopies.tool_environment(context[:scope], context[:working_dir])

      # Record the project's identity in the project itself. Without this, this
      # directory is only findable by a `local_path` lookup — a database query
      # keyed by a filesystem path, which is exactly what stops working once
      # the tools move to a server that has no filesystem.
      ensure_project_id_in_config(env, project.id)

      installed = Installers.install_all(env)

      BootstrapMapper.init_success(
        "local_path: #{working_dir}#{install_summary(installed)}",
        project.name
      )
    else
      {:error, reason} when reason in [:not_authenticated, :needs_authentication] ->
        BootstrapMapper.not_authenticated_error()

      {:error, reason} ->
        BootstrapMapper.error("#{reason}")
    end
  end

  @config_path ".code_my_spec/config.yml"

  # Prepended, never appended, and never round-tripped.
  #
  # `config.yml` carries a `description` that is a multi-line quoted scalar
  # spanning most of the file. Parsing and re-emitting it would put a
  # hand-written document through a serializer that has no reason to preserve
  # it, and appending risks landing inside that block if the file does not end
  # where it looks like it ends. The first line is always a top-level key, so a
  # top-level key placed before it cannot be swallowed by anything.
  #
  # Existing values win: an id already in the file is the project's own answer,
  # and re-linking must not silently repoint a directory at something else.
  defp ensure_project_id_in_config(env, project_id) do
    case Environments.read_file(env, @config_path) do
      {:ok, content} ->
        if Regex.match?(~r/^project_id:/m, content) do
          :ok
        else
          Environments.write_file(env, @config_path, "project_id: #{project_id}\n" <> content)
        end

      {:error, _} ->
        Environments.write_file(env, @config_path, "project_id: #{project_id}\n")
    end
  end

  # Surfaced in the tool reply so a failed install is visible at the moment it
  # happens, rather than showing up later as an unexplained unsatisfied
  # `project_setup` requirement.
  defp install_summary({installed, []}) do
    "\ninstalled: #{Enum.join(installed, ", ")}"
  end

  defp install_summary({installed, failures}) do
    failed =
      Enum.map_join(failures, ", ", fn {label, reason} -> "#{label} (#{inspect(reason)})" end)

    installed_part =
      if installed == [], do: "", else: "\ninstalled: #{Enum.join(installed, ", ")}"

    "#{installed_part}\nFAILED to install: #{failed} — run the matching install_* tool for details"
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
