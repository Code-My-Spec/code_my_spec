defmodule CodeMySpec.McpServers.Knowledge.Tools.ListKnowledge do
  @moduledoc """
  Browse the knowledge base directory tree.

  Lists entries in a knowledge library directory. Returns directories and files
  at the given path level.

  Libraries:
  - `knowledge` — Framework reference (LiveView, DaisyUI, Boundary, etc.)
  - `project_knowledge` — Project-specific research and decisions
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Validators
  alias CodeMySpecLocalWeb.MarkdownBrowserLive

  schema do
    field :library, :string,
      description:
        "Which knowledge library: 'knowledge' (framework) or 'project_knowledge' (project-specific). Default: 'knowledge'"

    field :path, :string,
      description: "Subdirectory path to list (e.g. 'liveview' or 'decisions/2026'). Default: root"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      library = library_atom(params)
      path_segments = parse_path(params)
      project_name = scope.active_project.name

      case MarkdownBrowserLive.resolve(library, path_segments, project_name) do
        {:ok, content} ->
          {:reply, text_response(content), frame}

        {:error, :not_found} ->
          {:reply, error_response("Path not found"), frame}

        {:error, :invalid_path} ->
          {:reply, error_response("Invalid path"), frame}

        {:error, reason} ->
          {:reply, error_response("#{inspect(reason)}"), frame}
      end
    else
      {:error, reason} ->
        {:reply, error_response("#{reason}"), frame}
    end
  end

  defp library_atom(%{"library" => "project_knowledge"}), do: :project_knowledge
  defp library_atom(_), do: :knowledge

  defp parse_path(%{"path" => path}) when is_binary(path) and path != "" do
    String.split(path, "/", trim: true)
  end

  defp parse_path(_), do: []

  defp text_response(content) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.text(content)
  end

  defp error_response(message) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.error(message)
  end
end
