defmodule CodeMySpec.Problems.ProblemAssigner do
  @moduledoc """
  Maps problems to components using file path matching.

  Uses the path index from `DirtyTracker.build_path_index/2` to assign
  `component_id` to each problem based on its `file_path`.
  """

  alias CodeMySpec.Problems.Problem

  @doc """
  Assigns `component_id` to each problem by matching its `file_path` against
  the path-to-component index.

  Problems whose file_path doesn't match any component get `component_id: nil`
  (e.g., compiler errors from deps or generated code).
  """
  @spec assign([Problem.t() | map()], %{String.t() => binary()}) :: [Problem.t() | map()]
  def assign(problems, path_to_component_map) do
    Enum.map(problems, fn problem ->
      file_path = get_file_path(problem)
      component_id = match_path(file_path, path_to_component_map)
      put_component_id(problem, component_id)
    end)
  end

  defp get_file_path(%Problem{file_path: path}), do: path
  defp get_file_path(%{file_path: path}), do: path
  defp get_file_path(_), do: nil

  defp put_component_id(%Problem{} = problem, id), do: %{problem | component_id: id}
  defp put_component_id(%{} = map, id), do: Map.put(map, :component_id, id)

  defp match_path(nil, _map), do: nil

  defp match_path(path, map) do
    Map.get(map, path) ||
      Enum.find_value(map, fn {rel, id} ->
        if String.ends_with?(path, rel) or String.ends_with?(rel, path), do: id
      end)
  end
end
