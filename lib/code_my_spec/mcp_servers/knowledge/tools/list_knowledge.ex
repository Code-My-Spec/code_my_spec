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

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias Anubis.Server.Response
  alias CodeMySpec.Knowledge
  alias CodeMySpec.McpServers.Validators

  schema do
    field :library, :string,
      description:
        "Which knowledge library: 'knowledge' (framework) or 'project_knowledge' (project-specific). Default: 'knowledge'"

    field :path, :string,
      description: "Subdirectory path to list (e.g. 'liveview' or 'decisions/2026'). Default: root"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, library} <- library_atom(params),
         {:ok, scope} <- Validators.validate_local_scope(frame) do
      path_segments = parse_path(params)

      case Knowledge.resolve(scope, library, path_segments) do
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
      {:error, {:invalid_library, value}} ->
        {:reply,
         error_response(
           "Invalid library #{inspect(value)}. Use 'knowledge' or 'project_knowledge'."
         ), frame}

      {:error, reason} ->
        {:reply, error_response("#{reason}"), frame}
    end
  end

  # `Knowledge.browse/3` already returns structured data rather than rendered
  # markdown -- it exists for the LiveView display surface, and a script
  # needs exactly the same thing `resolve/3` throws away by rendering it.
  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(params, frame) do
    with {:ok, library} <- library_atom(params),
         {:ok, scope} <- Validators.validate_local_scope(frame) do
      path_segments = parse_path(params)

      case Knowledge.browse(scope, library, path_segments) do
        {:ok, {:dir, entries}} ->
          {:ok, %{"type" => "dir", "entries" => Enum.map(entries, &entry_row/1)}}

        {:ok, {:file, content}} ->
          {:ok, %{"type" => "file", "content" => content}}

        {:error, :not_found} ->
          {:error, "Path not found"}

        {:error, :invalid_path} ->
          {:error, "Invalid path"}

        {:error, reason} ->
          {:error, "#{inspect(reason)}"}
      end
    else
      {:error, {:invalid_library, value}} ->
        {:error, "Invalid library #{inspect(value)}. Use 'knowledge' or 'project_knowledge'."}

      {:error, reason} ->
        {:error, "#{reason}"}
    end
  end

  defp entry_row({name, type, rel_path}) do
    %{"name" => name, "type" => to_string(type), "path" => rel_path}
  end

  defp library_atom(%{library: nil}), do: {:ok, :knowledge}
  defp library_atom(%{library: "knowledge"}), do: {:ok, :knowledge}
  defp library_atom(%{library: "project_knowledge"}), do: {:ok, :project_knowledge}
  defp library_atom(%{library: other}), do: {:error, {:invalid_library, other}}
  defp library_atom(_), do: {:ok, :knowledge}

  defp parse_path(%{path: path}) when is_binary(path) and path != "" do
    String.split(path, "/", trim: true)
  end

  defp parse_path(_), do: []

  defp text_response(content) do
    Response.tool()
    |> Response.text(content)
  end

  defp error_response(message) do
    Response.tool()
    |> Response.error(message)
  end
end
