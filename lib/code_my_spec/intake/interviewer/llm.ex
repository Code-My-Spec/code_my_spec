defmodule CodeMySpec.Intake.Interviewer.Llm do
  @moduledoc """
  The story interview, run by a model — through `CodeMySpec.Intake.Agent`,
  the same mechanism the shaper and the planner use.

  This is the differentiated part of the product and the cheap part — an
  interview is tokens. It runs while the workspace is still coming up, so the
  visitor is in a conversation rather than watching a bar, and the questions
  have to earn their place: there are at most four before they are shown what
  those answers imply.

  What is specific here is the prompt and the two tools below (`ask_question`,
  `derive_rules`); the mechanism — resolving a provider from `:model`, the
  `until_tool` call, extracting the tool call's input — is shared, not
  reimplemented per call site.
  """

  @behaviour CodeMySpec.Intake.Interviewer

  alias CodeMySpec.Intake.{Agent, Plan, Turn}

  require Logger

  @default_model "anthropic:claude-sonnet-5"

  @impl true
  def ask(%Plan{} = plan, turns) do
    prompt = """
    #{context(plan, turns)}

    Ask the single most useful next question about what this application should
    do — the thing you would most regret not knowing before building it.

    One question, one sentence, in their words. Ask about behaviour and rules,
    never about technology, frameworks or hosting. Do not repeat anything
    already asked or already answered above.

    If their last answer was not about the application, do not follow it and do
    not answer it. Ask again in plainer terms. You are here to work out what
    this application should do and nothing else.

    Call `ask_question` with the question. Do not answer in plain text.
    """

    run(prompt, ask_question_tool(), "question")
  end

  @impl true
  def derive(%Plan{} = plan, turns) do
    prompt = """
    #{context(plan, turns)}

    Write down the rules these answers imply — the things that must be true of
    the finished application. State them the way the visitor would recognise
    them, not as specifications, and only state what the answers actually
    support. Do not invent rules nobody agreed to.

    Call `derive_rules` with three to six rules. Do not answer in plain text.
    """

    run(prompt, derive_rules_tool(), "rules")
  end

  # No `extra_body: %{temperature: ...}` here — Alloy's Anthropic provider
  # runs with extended thinking on, and Anthropic rejects any temperature
  # other than the default (1) once thinking is enabled
  # (`invalid_request_error: temperature is deprecated for this model`). The
  # shaper never set one for the same reason; this used to and broke every
  # real interview call.
  defp run(prompt, tool, field) do
    run_opts = [model: model(), req_options: configured_req_options()]

    case Agent.run(prompt, tool, run_opts) do
      {:ok, input} -> {:ok, fetch(input, field)}
      {:error, reason} -> failed(field, reason)
    end
  end

  defp fetch(input, key), do: input[key] || input[String.to_existing_atom(key)]

  defp ask_question_tool do
    Alloy.Tool.inline(
      name: "ask_question",
      description: "Submit the next question to ask the visitor.",
      input_schema: %{
        type: "object",
        properties: %{
          question: %{
            type: "string",
            description:
              "One short question, in plain language, about what the application should do."
          }
        },
        required: ["question"]
      },
      execute: fn _input, _context -> {:ok, "Recorded."} end
    )
  end

  defp derive_rules_tool do
    Alloy.Tool.inline(
      name: "derive_rules",
      description: "Submit the rules these answers imply.",
      input_schema: %{
        type: "object",
        properties: %{
          rules: %{
            type: "array",
            items: %{type: "string"},
            description:
              "Three to six short rules, each one sentence, stated in the visitor's own terms."
          }
        },
        required: ["rules"]
      },
      execute: fn _input, _context -> {:ok, "Recorded."} end
    )
  end

  defp context(%Plan{} = plan, turns) do
    """
    Someone is building an application. Here is what they said they want:

    > #{plan.description}

    What we already concluded, and they confirmed:

    #{plan.summary}

    The conversation so far:

    #{transcript(turns)}
    """
  end

  defp transcript([]), do: "(nothing yet — this is the first question)"

  defp transcript(turns) do
    Enum.map_join(turns, "\n", fn %Turn{} = turn ->
      "Q: #{turn.question}\nA: #{turn.answer || "(unanswered)"}"
    end)
  end

  defp failed(step, reason) do
    Logger.error("[Intake.Interviewer] #{step} failed: #{inspect(reason)}")
    {:error, :interview_unavailable}
  end

  # A test's cassette plug, most often — merged onto `Agent.run/3`'s own
  # default timeout.
  defp configured_req_options,
    do: Application.get_env(:code_my_spec, CodeMySpec.Intake, [])[:req_options] || []

  # Shares `:model` with the shaper rather than a separate `:interviewer_model`
  # — both are quick Q&A calls against the same conversation, and a second
  # knob nothing set was drift waiting to happen, the same mistake the planner
  # already made and fixed with its own `:planner_model`.
  defp model do
    Application.get_env(:code_my_spec, CodeMySpec.Intake, [])[:model] || @default_model
  end
end
