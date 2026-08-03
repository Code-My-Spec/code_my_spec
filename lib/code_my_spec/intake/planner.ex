defmodule CodeMySpec.Intake.Planner do
  @moduledoc """
  Turns a visitor's description and answers into the plan they are shown.

  The implementation is swappable because the real one is an LLM call and
  `req_llm` is not on main yet. Configure with:

      config :code_my_spec, CodeMySpec.Intake, planner: MyPlanner
  """

  alias CodeMySpec.Intake.Plan

  @type plan_attrs :: %{
          summary: String.t(),
          first_build: String.t(),
          account_name: String.t(),
          project_name: String.t()
        }

  @callback generate(Plan.t()) :: {:ok, plan_attrs()} | {:error, term()}

  @spec generate(Plan.t()) :: {:ok, plan_attrs()} | {:error, term()}
  def generate(%Plan{} = plan), do: impl().generate(plan)

  defp impl do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Intake, [])
    |> Keyword.get(:planner, CodeMySpec.Intake.Planner.Inferred)
  end
end
