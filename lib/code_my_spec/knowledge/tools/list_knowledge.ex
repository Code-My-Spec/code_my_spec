defmodule CodeMySpec.Knowledge.Tools.ListKnowledge do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Knowledge
  alias CodeMySpec.Knowledge.Tools

  @impl true
  def name, do: "list_knowledge"

  @impl true
  def description do
    """
    Browse the knowledge base directory tree.

    Lists entries in a knowledge library directory. Returns directories and files
    at the given path level.

    Libraries:
    - `knowledge` — Framework reference (LiveView, DaisyUI, Boundary, etc.)
    - `project_knowledge` — Project-specific research and decisions
    """
  end

  @impl true
  def params do
    %{
      library:
        {:meta, :string,
         [
           description:
             "Which knowledge library: 'knowledge' (framework) or 'project_knowledge' (project-specific). Default: 'knowledge'"
         ]},
      path:
        {:meta, :string,
         [
           description:
             "Subdirectory path to list (e.g. 'liveview' or 'decisions/2026'). Default: root"
         ]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, library} <- Tools.library(params),
         {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, content} <- Knowledge.resolve(scope, library, Tools.path(params)) do
      {:ok, content}
    else
      {:error, reason} -> Tools.error(reason)
    end
  end

  @impl true
  def script_result(params, context) do
    with {:ok, library} <- Tools.library(params),
         {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, content} <- Knowledge.browse(scope, library, Tools.path(params)) do
      {:ok, row(content)}
    else
      {:error, reason} -> Tools.error(reason)
    end
  end

  defp row({:dir, entries}),
    do: %{"type" => "dir", "entries" => Enum.map(entries, &entry/1)}

  defp row({:file, content}), do: %{"type" => "file", "content" => content}

  defp entry({name, type, path}),
    do: %{"name" => name, "type" => to_string(type), "path" => path}
end
