defmodule CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge do
  @moduledoc """
  Read a specific knowledge entry by path.

  Returns the full markdown content of a knowledge file.

  Libraries:
  - `knowledge` — Framework reference (LiveView, DaisyUI, Boundary, etc.)
  - `project_knowledge` — Project-specific research and decisions
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Validators
  alias CodeMySpecLocalWeb.MarkdownBrowserLive

  schema do
    field :path, :string,
      required: true,
      description: "Path to the knowledge file (e.g. 'liveview/forms.md' or 'decisions/adr-001.md')"

    field :library, :string,
      description:
        "Which knowledge library: 'knowledge' (framework) or 'project_knowledge' (project-specific). Default: 'knowledge'"
  end

  @impl true
  def execute(%{path: path} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      library = library_atom(params)
      path_segments = String.split(path, "/", trim: true)
      project_name = scope.active_project.name

      case MarkdownBrowserLive.resolve(library, path_segments, project_name) do
        {:ok, content} ->
          {:reply, text_response(content), frame}

        {:error, :not_found} ->
          {:reply, error_response("Knowledge entry not found: #{path}"), frame}

        {:error, :invalid_path} ->
          {:reply, error_response("Invalid path: #{path}"), frame}

        {:error, reason} ->
          {:reply, error_response("#{inspect(reason)}"), frame}
      end
    else
      {:error, reason} ->
        {:reply, error_response("#{reason}"), frame}
    end
  end

  defp library_atom(%{library: "project_knowledge"}), do: :project_knowledge
  defp library_atom(_), do: :knowledge

  defp text_response(content) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.text(content)
  end

  defp error_response(message) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.error(message)
  end
end
