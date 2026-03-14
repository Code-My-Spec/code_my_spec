defmodule CodeMySpec.Components.DirtyTracker do
  @moduledoc """
  Queries dirty components and records analysis timestamps.

  A component is "analysis dirty" when `files_changed_at > last_analyzed_at`.

  `files_changed_at` is set by `Components.Sync` to the max mtime of the
  component's spec and implementation files.

  Testing uses `mix test --stale` (Elixir's manifest-based stale tracking)
  and spex uses `mix spex --stale` — neither needs DB timestamps.
  """

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

  @doc """
  Returns components that are dirty for analysis (compiler, credo, sobelow).
  """
  @spec dirty_for_analysis(Scope.t()) :: [Component.t()]
  def dirty_for_analysis(%Scope{} = scope) do
    scope
    |> Components.list_components()
    |> Enum.filter(&analysis_dirty?/1)
  end

  @doc """
  Check if a component needs re-analysis (compiler, credo, sobelow).
  """
  @spec analysis_dirty?(Component.t()) :: boolean()
  def analysis_dirty?(%Component{} = component) do
    dirty?(component.files_changed_at, component.last_analyzed_at)
  end

  @doc """
  Record that analysis tools have run on these components.
  Sets `last_analyzed_at` to now.
  """
  @spec record_analysis(Scope.t(), [Component.t()]) :: :ok
  def record_analysis(%Scope{} = scope, components) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(components, fn component ->
      Components.update_component(scope, component, %{last_analyzed_at: now}, broadcast: false)
    end)
  end

  @doc """
  Build reverse index: relative file path => component_id.
  Also returns component_id => file map for collecting dirty files.
  """
  @spec build_path_index([Component.t()], term()) ::
          {%{String.t() => binary()}, %{binary() => %{atom() => String.t()}}}
  def build_path_index(components, project) do
    Enum.reduce(components, {%{}, %{}}, fn component, {path_map, files_map} ->
      files = Utils.component_files(component, project)

      path_map =
        for {_role, rel_path} <- files, reduce: path_map do
          acc -> Map.put(acc, rel_path, component.id)
        end

      {path_map, Map.put(files_map, component.id, files)}
    end)
  end

  # A component is dirty when files have changed but haven't been processed yet.
  defp dirty?(nil, _last_processed_at), do: false
  defp dirty?(_changed_at, nil), do: true

  defp dirty?(changed_at, last_processed_at) do
    DateTime.compare(changed_at, last_processed_at) == :gt
  end
end
