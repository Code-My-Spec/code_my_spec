defmodule CodeMySpec.McpServers.Architecture.Tools.ShowNamespaceHierarchy do
  @moduledoc """
  The project's components as a module-namespace tree: the first thing to read
  for an architectural overview. Two levels by default; `prefix` and `depth`
  open one subtree further. A node cut off by the depth shows `(+N)`, the
  components below it.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Architecture.NamespaceProjector
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  @default_depth 2

  schema do
    field :prefix, :string, description: "Only this namespace, e.g. MyApp.Accounts."

    field :depth, :integer,
      description:
        "Levels to show below the prefix (from the top without one). Default #{@default_depth}."

    field :descriptions, :boolean, description: "Include descriptions. Default true."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_scope(frame) do
      {:ok, scope} ->
        tree =
          scope
          |> Components.list_components()
          |> NamespaceProjector.project(options(params))

        {:reply, Response.text(Response.tool(), text(tree, params)), frame}

      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
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
