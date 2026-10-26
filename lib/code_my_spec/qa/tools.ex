defmodule CodeMySpec.Qa.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.CodeMode,
      CodeMySpec.Projects,
      CodeMySpec.Qa,
      CodeMySpec.Stories,
      CodeMySpec.Tools,
      CodeMySpec.WorkingCopies
    ]

  @doc "Keep scenario positions in validation errors before schema casting loses list indices."
  def validate_scenarios(params, tool_name) do
    case Map.get(params, :scenarios, Map.get(params, "scenarios")) do
      scenarios when is_list(scenarios) ->
        errors =
          scenarios
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {scenario, index} ->
            if is_map(scenario) do
              scenario
              |> CodeMySpec.Qa.Scenario.changeset()
              |> CodeMySpec.Tools.changeset_error_map()
              |> Enum.map(fn {field, messages} ->
                "##{index} #{field}: #{Enum.join(messages, ", ")}"
              end)
            else
              ["##{index} must be a scenario object"]
            end
          end)

        if errors == [],
          do: :ok,
          else: {:error, "Invalid #{tool_name} payload: " <> Enum.join(errors, "; ")}

      _ ->
        :ok
    end
  end

  def all do
    [
      CodeMySpec.Qa.Tools.CallMcpServer,
      CodeMySpec.Qa.Tools.GetLocalAppToken,
      CodeMySpec.Qa.Tools.InvalidateQaAttempt,
      CodeMySpec.Qa.Tools.ListQaAttempts,
      CodeMySpec.Qa.Tools.RemoveQaEvidence,
      CodeMySpec.Qa.Tools.SubmitIssueQaResult,
      CodeMySpec.Qa.Tools.SubmitQaResult
    ]
  end
end
