defmodule CodeMySpec.Intake.Interviewer.Llm do
  @moduledoc """
  The interview, run by a model.

  This is the differentiated part of the product and the cheap part — an
  interview is tokens. It runs while the workspace is still coming up, so the
  visitor is in a conversation rather than watching a bar, and the questions
  have to earn their place: there are at most four before they are shown what
  those answers imply.
  """

  @behaviour CodeMySpec.Intake.Interviewer

  alias CodeMySpec.Intake.{Plan, Turn}

  require Logger

  @default_model "anthropic:claude-sonnet-5"

  @question_schema [
    question: [
      type: :string,
      required: true,
      doc: "One short question, in plain language, about what the application should do."
    ]
  ]

  @rules_schema [
    rules: [
      type: {:list, :string},
      required: true,
      doc: "Three to six short rules, each one sentence, stated in the visitor's own terms."
    ]
  ]

  @impl true
  def ask(%Plan{} = plan, turns) do
    prompt = """
    #{context(plan, turns)}

    Ask the single most useful next question about what this application should
    do — the thing you would most regret not knowing before building it.

    One question, one sentence, in their words. Ask about behaviour and rules,
    never about technology, frameworks or hosting. Do not repeat anything
    already asked or already answered above.
    """

    case ReqLLM.generate_object(model(), prompt, @question_schema, temperature: 0.4) do
      {:ok, response} -> {:ok, response |> ReqLLM.Response.object() |> fetch("question")}
      {:error, reason} -> failed(:ask, reason)
    end
  end

  @impl true
  def derive(%Plan{} = plan, turns) do
    prompt = """
    #{context(plan, turns)}

    Write down the rules these answers imply — the things that must be true of
    the finished application. State them the way the visitor would recognise
    them, not as specifications, and only state what the answers actually
    support. Do not invent rules nobody agreed to.
    """

    case ReqLLM.generate_object(model(), prompt, @rules_schema, temperature: 0.2) do
      {:ok, response} -> {:ok, response |> ReqLLM.Response.object() |> fetch("rules")}
      {:error, reason} -> failed(:derive, reason)
    end
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

  defp fetch(object, key), do: object[key] || object[String.to_existing_atom(key)]

  defp failed(step, reason) do
    Logger.error("[Intake.Interviewer] #{step} failed: #{inspect(reason)}")
    {:error, :interview_unavailable}
  end

  defp model do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Intake, [])
    |> Keyword.get(:interviewer_model, @default_model)
  end
end
