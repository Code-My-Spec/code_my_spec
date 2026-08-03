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
    |> Keyword.get_lazy(:planner, &default_impl/0)
  end

  # The model writes the plan when there is a key to reach it with, and the
  # offline heuristic writes it when there is not. A hard default on the model
  # would mean every visitor hits a failure the moment the key is missing —
  # a worse first impression than a plainly-worded plan.
  defp default_impl do
    # `:anthropic_api_key`, not `:anthropic` — get_key/1 with an atom is a
    # straight `Application.get_env(:req_llm, key)`, so the name has to match
    # the config key exactly or it silently reads nil and falls back.
    case ReqLLM.get_key(:anthropic_api_key) do
      key when is_binary(key) and key != "" -> CodeMySpec.Intake.Planner.Llm
      _ -> CodeMySpec.Intake.Planner.Inferred
    end
  end
end
