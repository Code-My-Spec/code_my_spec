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

  @doc false
  # Public so which implementation a configuration selects can be asserted
  # directly. The bug was a provider name hardcoded in that choice, and it is
  # invisible from the outside — the heuristic answers successfully, it just
  # answers worse.
  @spec impl_for_test() :: module()
  def impl_for_test, do: impl()

  defp impl do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Intake, [])
    |> Keyword.get_lazy(:planner, &default_impl/0)
  end

  # The model writes the plan when there is a key to reach it with, and the
  # offline heuristic writes it when there is not. A hard default on the model
  # would mean every visitor hits a failure the moment the key is missing —
  # a worse first impression than a plainly-worded plan.
  #
  # `Agent.key_configured?/1` is named after the *configured model*'s
  # provider, not a fixed one — this used to ask for `:anthropic_api_key` by
  # name, so a deployment holding an OpenAI key and an OpenAI model still
  # answered "no key" and fell through to the heuristic — every visitor,
  # silently, while the shaper beside it called OpenAI happily. That is what
  # wrote "a beginners for Beginner mahjong players" and named the project
  # "Beginners", and it reads as the model being stupid rather than absent.
  defp default_impl do
    if CodeMySpec.Intake.Agent.key_configured?(planner_model()),
      do: CodeMySpec.Intake.Planner.Llm,
      else: CodeMySpec.Intake.Planner.Inferred
  end

  defp planner_model do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Intake, [])
    |> Keyword.get(:planner_model, "anthropic:claude-sonnet-5")
  end
end
