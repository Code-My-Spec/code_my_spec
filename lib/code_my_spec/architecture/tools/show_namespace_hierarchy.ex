defmodule CodeMySpec.Architecture.Tools.ShowNamespaceHierarchy do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Architecture.NamespaceProjector
  alias CodeMySpec.Components
  alias CodeMySpec.Architecture.Tools.Responses, as: ArchitectureMapper

  @default_depth 2

  @impl true
  def name, do: "show_namespace_hierarchy"

  @impl true
  def description do
    """
    The project's components as a module-namespace tree: the first thing to read
    for an architectural overview. Two levels by default; `prefix` and `depth`
    open one subtree further. A node cut off by the depth shows `(+N)`, the
    components below it.
    """
  end

  @impl true
  def params do
    %{
      depth:
        {:meta, :integer,
         [description: "Levels to show below the prefix (from the top without one). Default 2."]},
      prefix: {:meta, :string, [description: "Only this namespace, e.g. MyApp.Accounts."]},
      descriptions: {:meta, :boolean, [description: "Include descriptions. Default true."]}
    }
  end

  @impl true
  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        tree =
          scope
          |> Components.list_components()
          |> NamespaceProjector.project(options(params))

        {:ok, text(tree, params)}

      {:error, reason} ->
        ArchitectureMapper.error(reason)
    end
  end

  defp options(params) do
    prefix = params[:prefix]
    above = if prefix, do: length(String.split(prefix, ".")), else: 0

    [
      filter_prefix: prefix,
      max_depth: above + (params[:depth] || @default_depth),
      show_descriptions: params[:descriptions] != false
    ]
  end

  defp text("", %{prefix: prefix}) when is_binary(prefix), do: "No components under #{prefix}."
  defp text("", _params), do: "No components yet."
  defp text(tree, _params), do: tree
end
