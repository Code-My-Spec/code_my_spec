defmodule CodeMySpec.Intake.PlannerProviderTest do
  @moduledoc """
  The planner looks for the key the model it is configured to use needs.

  It asked for `:anthropic_api_key` by name. A deployment holding an OpenAI key
  and an OpenAI model therefore answered "no key", fell through to the offline
  heuristic, and did so silently — every visitor, while the shaper beside it
  called OpenAI happily on the same request.

  The heuristic is a fine last resort and a poor plan: it wrote "You're building
  a beginners for Beginner mahjong players" and named both the account and the
  project "Beginners". Reported as the model doing a poor job. No model had run.
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Planner

  setup do
    intake = Application.get_env(:code_my_spec, Intake, [])
    anthropic = Application.get_env(:req_llm, :anthropic_api_key)
    openai = Application.get_env(:req_llm, :openai_api_key)

    on_exit(fn ->
      Application.put_env(:code_my_spec, Intake, intake)
      restore(:anthropic_api_key, anthropic)
      restore(:openai_api_key, openai)
    end)

    # No planner override, so `default_impl/0` is what answers.
    Application.put_env(:code_my_spec, Intake, Keyword.delete(intake, :planner))
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:req_llm, key)
  defp restore(key, value), do: Application.put_env(:req_llm, key, value)

  defp configure(model, keys) do
    Application.put_env(
      :code_my_spec,
      Intake,
      Keyword.put(Application.get_env(:code_my_spec, Intake, []), :planner_model, model)
    )

    for key <- [:anthropic_api_key, :openai_api_key] do
      set_or_clear(key, Keyword.get(keys, key))
    end
  end

  defp set_or_clear(key, nil), do: Application.delete_env(:req_llm, key)
  defp set_or_clear(key, value), do: Application.put_env(:req_llm, key, value)

  test "an OpenAI model with an OpenAI key uses the model" do
    configure("openai:gpt-5-mini", openai_api_key: "sk-test")

    assert Planner.impl_for_test() == CodeMySpec.Intake.Planner.Llm,
           "the planner fell back to the offline heuristic on a deployment that can " <>
             "reach a model. It looked for an Anthropic key by name, so every " <>
             "OpenAI deployment silently wrote heuristic plans."
  end

  test "an Anthropic model with an Anthropic key still uses the model" do
    configure("anthropic:claude-sonnet-5", anthropic_api_key: "sk-ant-test")

    assert Planner.impl_for_test() == CodeMySpec.Intake.Planner.Llm
  end

  test "a model whose provider has no key falls back, which is the point" do
    configure("openai:gpt-5-mini", anthropic_api_key: "sk-ant-test")

    assert Planner.impl_for_test() == CodeMySpec.Intake.Planner.Inferred,
           "holding some other provider's key is not the same as being able to reach " <>
             "the configured model — falling back is right here, and a plainly-worded " <>
             "plan beats an error on a visitor's first screen"
  end
end
