defmodule CodeMySpec.McpServers.Problems.Tools.ClearProblems do
  @moduledoc """
  Clear stale persisted problems for the current project so a fixed file
  stops blocking the Stop hook.

  Problems are cleared per-source-per-file as validators re-run: a run only
  clears problems for the files it re-checks. So when you fix a file but a
  later run doesn't re-check that exact path, its old problem lingers and the
  Stop hook keeps blocking on it even though the code is correct.

  Use this tool when you have verified a reported problem is stale — the
  underlying file is fixed and the failure no longer reproduces — but the
  Stop hook keeps replaying it.

  - Pass `file_paths` to clear only those files' problems (preferred: targeted,
    won't wipe unrelated findings).
  - Omit `file_paths` to clear ALL persisted problems for the project (blunt
    reset — use when the whole stored set is stale).

  This only clears the *stored* problem records the Stop hook reads; it does
  not modify code or re-run analysis. If the problem is real, it will be
  re-recorded on the next validation run.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Problems

  schema do
    field :file_paths, {:list, :string},
      doc:
        "Project-relative file paths whose stale problems should be cleared. " <>
          "Omit to clear ALL persisted problems for the project."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params) do
      case file_paths(params) do
        [] ->
          {:ok, count} = Problems.clear_project_problems(scope)
          {:reply, ok(cleared_all_summary(count)), frame}

        paths ->
          {:ok, _} = Problems.replace_problems_for_files(scope, paths, [])
          {:reply, ok(cleared_files_summary(paths)), frame}
      end
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp file_paths(params) do
    case Map.get(params, :file_paths) do
      list when is_list(list) -> Enum.reject(list, &(&1 in [nil, ""]))
      _ -> []
    end
  end

  defp cleared_all_summary(count),
    do: "Cleared #{count} persisted problem(s) for the project. Re-run validation to re-record any that are still real."

  defp cleared_files_summary(paths),
    do:
      "Cleared persisted problems for #{length(paths)} file(s): #{Enum.join(paths, ", ")}. " <>
        "Re-run validation to re-record any that are still real."

  defp ok(summary), do: Response.tool() |> Response.text(summary)

  defp error(reason) when is_atom(reason),
    do: Response.tool() |> Response.error("Could not clear problems: #{reason}")

  defp error(reason),
    do: Response.tool() |> Response.error("Could not clear problems: #{inspect(reason)}")
end
