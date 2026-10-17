defmodule CodeMySpec.Problems.Tools.ClearProblems do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Problems.Tools

  @impl true
  def name, do: "clear_problems"

  @impl true
  def description do
    """
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
  end

  @impl true
  def params do
    %{
      file_paths:
        {:meta, {:list, :string},
         [
           description:
             "Project-relative file paths whose stale problems should be cleared. " <>
               "Omit to clear ALL persisted problems for the project."
         ]}
    }
  end

  @impl true
  def call(params, context), do: Tools.clear(params, context)
end
