defmodule CodeMySpec.AgentTasks.ProblemFeedback do
  @moduledoc """
  Shared problem feedback for agent task evaluation.

  Queries persisted problems for component files and formats actionable feedback
  for the model. Each task type has different rules for which problems to include.
  """

  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.ProblemRenderer
  alias CodeMySpec.Utils

  @doc """
  Query all problems for a component's code file and test file.

  Returns formatted feedback string or nil if no problems exist.
  """
  @spec for_code_task(term(), term(), term()) :: String.t() | nil
  def for_code_task(scope, component, project) do
    %{code_file: code_file, test_file: test_file} = Utils.component_files(component, project)

    problems =
      Problems.list_project_problems(scope, file_path: code_file) ++
        Problems.list_project_problems(scope, file_path: test_file)

    format_if_present(problems, context: "Problems found in implementation files:")
  end

  @doc """
  Query problems for a component's test file, excluding test failures.

  Test failures (source_type == :test) are filtered out because they are
  expected in TDD mode when the implementation doesn't exist yet.

  Returns formatted feedback string or nil if no problems remain.
  """
  @spec for_test_task(term(), term(), term()) :: String.t() | nil
  def for_test_task(scope, component, project) do
    %{test_file: test_file} = Utils.component_files(component, project)

    problems =
      Problems.list_project_problems(scope, file_path: test_file)
      |> Enum.reject(&(&1.source_type == :test))

    format_if_present(problems,
      context: "Test file has problems (test failures are OK, these are not):"
    )
  end

  @doc """
  The evaluate result for a task: met requirements pass, whatever problems are
  persisted.

  A task completes when its requirement is met, even on a red run (John,
  2026-10-04): red blocks at promotion and ready_for_qa certification, and the
  stop reports it as feedback. Problems only ride along as context on a task
  that is already invalid for its requirements.
  """
  @spec combine(String.t() | nil, String.t() | nil) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def combine(nil, _problem_feedback), do: {:ok, :valid}
  def combine(req_feedback, nil) when is_binary(req_feedback), do: {:ok, :invalid, req_feedback}

  def combine(req_feedback, problem_feedback)
      when is_binary(req_feedback) and is_binary(problem_feedback) do
    {:ok, :invalid, Enum.join([req_feedback, problem_feedback], "\n\n")}
  end

  defp format_if_present([], _opts), do: nil

  defp format_if_present(problems, opts) do
    ProblemRenderer.render_for_feedback(problems,
      context: opts[:context],
      max_problems: 20
    )
  end
end
