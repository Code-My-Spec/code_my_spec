defmodule CodeMySpec.Intake.Planner.Llm do
  @moduledoc """
  Reads the visitor's description and writes the plan they are shown.

  This is the differentiated part of guided intake and the cheap part: the
  interview is tokens, not compute, which is the whole structural argument for
  giving it away before the gate.

  Structured rather than free text, because the plan is not only prose — the
  account and project names it proposes get created if the visitor confirms
  them, so they have to come back as fields rather than be parsed out of a
  paragraph.
  """

  @behaviour CodeMySpec.Intake.Planner

  alias CodeMySpec.Intake.Plan

  require Logger

  @default_model "anthropic:claude-sonnet-5"

  @schema [
    summary: [
      type: :string,
      required: true,
      doc:
        "Two or three sentences, in the visitor's own words, describing what they are building."
    ],
    first_build: [
      type: :string,
      required: true,
      doc: "One sentence naming the first thing worth building, and why it comes first."
    ],
    account_name: [
      type: :string,
      required: true,
      doc: "A short name for the visitor's account — their business or team, in title case."
    ],
    project_name: [
      type: :string,
      required: true,
      doc: "A short name for this application, in title case. Not a description."
    ]
  ]

  @impl true
  def generate(%Plan{description: description} = plan) when is_binary(description) do
    # Same timeout reasoning as the shaper: Req defaults to 15s, this set none,
    # and the plan is the slower of the two calls. Measured on gpt-5-mini at
    # 12.5s and gpt-5 at 29.3s — a budget that fits neither reliably.
    case ReqLLM.generate_object(model(), prompt(plan), @schema,
           temperature: 0.3,
           receive_timeout: to_timeout(second: 120)
         ) do
      {:ok, response} -> {:ok, response |> ReqLLM.Response.object() |> to_attrs()}
      {:error, reason} -> failed(reason)
    end
  end

  # generate_object/4 answers with string keys; the behaviour is declared in
  # atoms and the offline planner returns atoms. Two implementations of one
  # callback disagreeing on key type is the kind of thing that survives until
  # something merges both maps and Ecto refuses the mix.
  defp to_attrs(object) do
    Map.new(@schema, fn {field, _spec} -> {field, field_value(object, field)} end)
  end

  # `Map.fetch/2` rather than `||`, matching the shaper. Every field here is a
  # string today, so `||` was not yet wrong — but it is the same expression that
  # silently turned a model's `false` into `nil` next door, and a schema gains a
  # boolean the moment somebody adds one.
  defp field_value(object, field) do
    case Map.fetch(object, to_string(field)) do
      {:ok, value} -> value
      :error -> Map.get(object, field)
    end
  end

  defp failed(reason) do
    Logger.error("[Intake.Planner] could not write a plan: #{inspect(reason)}")
    {:error, :plan_unavailable}
  end

  defp prompt(%Plan{} = plan) do
    """
    Someone has just landed on a tool that builds web applications, and has
    described what they want. Write back what you think they are building.

    They said:

    > #{plan.description}

    They also told you:
    - Do people need to sign in to use it? #{yes_no(plan.needs_sign_in)}
    - Does each separate business get its own copy of the data? #{yes_no(plan.separate_copies)}
    - Roughly who uses it? #{plan.who_uses || "they did not say"}

    Write the summary in second person, addressed to them, using their own
    vocabulary rather than ours — no jargon, no "multi-tenant", no
    "authentication". State plainly what you concluded about signing in and
    about separate copies, so they can correct you if you have it wrong.

    The names you propose get created as their account and project if they
    accept them, so make them short, real names — never a pronoun, never a
    word lifted out of the middle of their sentence.
    """
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
  defp yes_no(nil), do: "they did not say"

  # Configurable, like the shaper's. It was not, so it kept the Anthropic
  # default while the shaper followed `INTAKE_MODEL` to OpenAI — and on a
  # deployment holding only an OpenAI key that meant the planner could never
  # reach a model at all. It fell back to the offline heuristic silently, which
  # is what wrote "a beginners for mahjong players" and named the project
  # "Beginners". Two models behind one feature, one of them unreachable, and the
  # visible symptom was a plan that read as though the model were stupid.
  defp model do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Intake, [])
    |> Keyword.get(:planner_model, @default_model)
  end
end
