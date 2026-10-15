defmodule CodeMySpec.Knowledge.Tools.ReadKnowledge do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Knowledge
  alias CodeMySpec.Knowledge.Tools

  @impl true
  def name, do: "read_knowledge"

  @impl true
  def description do
    """
    Read a specific knowledge entry by path.

    Returns the full markdown content of a knowledge file.

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
        {:required,
         {:meta, :string,
          [
            description:
              "Path to the knowledge file (e.g. 'liveview/forms.md' or 'decisions/adr-001.md')"
          ]}}
    }
  end

  @impl true
  def call(%{path: path} = params, context) do
    with {:ok, library} <- Tools.library(params),
         {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, content} <- Knowledge.resolve(scope, library, Tools.path(params)) do
      {:ok, content}
    else
      {:error, :not_found} -> {:error, "Knowledge entry not found: #{path}"}
      {:error, :invalid_path} -> {:error, "Invalid path: #{path}"}
      {:error, reason} -> Tools.error(reason)
    end
  end
end
