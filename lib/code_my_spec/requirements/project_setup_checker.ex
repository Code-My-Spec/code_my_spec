defmodule CodeMySpec.Requirements.ProjectSetupChecker do
  @moduledoc """
  Checker for the project_setup requirement.

  Evaluates each setup step from `SetupSteps.all()` inline by calling
  the step module's `evaluate/3`. Reports a checklist in details.
  Satisfied when all steps pass.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Setup.SetupSteps
  alias CodeMySpec.Users.Scope

  def check(
        %Scope{} = scope,
        %RequirementDefinition{
          name: name,
          artifact_type: artifact_type,
          description: description,
          checker: checker,
          satisfied_by: satisfied_by
        },
        _entity,
        _opts \\ []
      ) do
    steps = SetupSteps.all()

    results =
      Enum.map(steps, fn step ->
        status =
          case step.module.evaluate(scope, %{}) do
            {:ok, :valid} -> :done
            {:ok, :invalid, detail} -> {:not_done, detail}
            _ -> {:not_done, "unknown"}
          end

        {step.id, step.name, status}
      end)

    total = length(results)
    done = Enum.count(results, fn {_, _, s} -> s == :done end)
    all_done = done == total

    checklist =
      Enum.map(results, fn {id, step_name, status} ->
        case status do
          :done -> %{id: id, name: step_name, satisfied: true}
          {:not_done, detail} -> %{id: id, name: step_name, satisfied: false, detail: detail}
        end
      end)

    %{
      name: name,
      artifact_type: artifact_type,
      description: description,
      checker_module: checker,
      satisfied_by: satisfied_by,
      satisfied: all_done,
      score: if(total > 0, do: Float.round(done / total, 2), else: 0.0),
      checked_at: DateTime.utc_now(),
      details: %{
        done: done,
        total: total,
        checklist: checklist
      }
    }
  end
end
