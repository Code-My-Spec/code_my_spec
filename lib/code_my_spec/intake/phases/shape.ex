defmodule CodeMySpec.Intake.Phases.Shape do
  @moduledoc """
  Phase one: work out what to build, from a conversation rather than a form.

  The form behind this phase is the two generator inputs — whether people sign in
  and whether each business runs its own copy — plus a few words on who uses it.
  The phase is finished when both booleans are answered. Everything else it does
  is in service of that: asking, at most twice, and only about the visitor's
  business.

  Sign-in and separate copies are our questions, not theirs. Someone with an idea
  for a booking tool has no view on tenancy and should not be asked to have one,
  so the model asks what a person would ask and infers the rest. "A booking tool
  for hair salons, my clients book slots" already answers both.

  ## The two-question cap

  This runs before the visitor has given us anything — no email, no account — so
  every question spends goodwill we have not earned, and the third is where
  people leave. At the cap the model does not get a say: `goal/1` stops offering
  the option and `commit/2` drops a question that arrives anyway. An intake that
  keeps asking is worse than one that guesses and shows its guess, and the guess
  is correctable on the next screen.

  ## Why this is a phase

  It was two behaviours — `Intake.Shaper` for the questions and `Intake.Planner`
  for what follows — each with an LLM implementation, a test double, and its own
  call into `Intake.Agent`. The prompt, the tool and the budget are the only
  parts that were ever about shaping. `CodeMySpec.Agents.Phase` holds the rest,
  and the planner is the next phase rather than another copy of the same
  plumbing.

  Nothing here writes to the database: the state is folded in memory and
  `CodeMySpec.Intake` persists the outcome, which is what keeps two tabs on one
  plan from racing through this module. See `CodeMySpec.Agents.Phase`.
  """

  @behaviour CodeMySpec.Agents.Phase

  alias CodeMySpec.Intake.Plan

  @max_questions 2
  @tool_name "shape_plan"

  @typedoc "A question already put to the visitor, and what they said back."
  @type turn :: %{question: String.t(), answer: String.t()}

  @type t :: %__MODULE__{
          plan: Plan.t(),
          turns: [turn()],
          question: String.t() | nil,
          attrs: map()
        }

  defstruct plan: nil, turns: [], question: nil, attrs: %{}

  @doc """
  The phase's starting state for a plan and the turns it has already spent.
  """
  @spec new(Plan.t(), [turn()]) :: t()
  def new(%Plan{} = plan, turns \\ []) when is_list(turns) do
    %__MODULE__{plan: plan, turns: turns}
  end

  @doc "How many questions this conversation may spend."
  @spec max_questions() :: pos_integer()
  def max_questions, do: @max_questions

  @doc """
  What the phase concluded, once it is complete.

  The question is scaffolding for the conversation, not part of the plan, so it
  is never in here — `answers_changeset/2` would reject the extra key anyway.
  """
  @spec answers(t()) :: map()
  def answers(%__MODULE__{attrs: attrs}), do: Map.delete(attrs, :question)

  # ============================================================================
  # Phase callbacks
  # ============================================================================

  @impl true
  def goal(%__MODULE__{plan: %Plan{description: description}, turns: turns} = state) do
    said =
      Enum.map_join(turns, "\n", fn %{question: q, answer: a} ->
        "You asked: #{q}\nThey said: #{a}"
      end)

    """
    Someone with an idea is describing an application they want built. They are not
    technical and have not signed up. Your job is to work out two things that decide
    what gets generated for them: whether people log in, and whether many separate
    businesses each run their own copy.

    What they want to build:
    #{description}
    #{if said == "", do: "", else: "\n" <> said <> "\n"}
    #{closing(state)}

    Call `#{@tool_name}` with all four fields. Do not answer in plain text.
    """
  end

  @impl true
  def tools(%__MODULE__{}), do: [shape_tool()]

  @impl true
  def commit(%__MODULE__{} = state, input) when is_map(input) do
    attrs = to_attrs(input)

    {:ok, %{state | attrs: Map.delete(attrs, :question), question: asked(state, attrs)}}
  end

  @impl true
  def evaluate(%__MODULE__{question: question}) when is_binary(question) do
    {:ask, question}
  end

  def evaluate(%__MODULE__{attrs: %{needs_sign_in: sign_in, separate_copies: copies}})
      when is_boolean(sign_in) and is_boolean(copies) do
    :complete
  end

  # Reached when the model called the tool but left a boolean out or answered it
  # in prose. Named rather than described, because the feedback goes back into
  # the next prompt and "both booleans" is not something a model can act on.
  def evaluate(%__MODULE__{attrs: attrs}) do
    {:incomplete,
     "#{missing(attrs)} must be true or false, and your answer did not set it. " <>
       "Decide from what they have already said."}
  end

  # ============================================================================
  # Prompt
  # ============================================================================

  defp closing(%__MODULE__{turns: turns}) when length(turns) >= @max_questions do
    """
    Do not ask anything. Return an empty question and your best reading of the
    answers from what they have already said, even if you are unsure — the
    visitor sees every one of these and can correct it.
    """
  end

  defp closing(%__MODULE__{}) do
    """
    If what they have said already tells you whether people sign in and whether
    each business runs its own copy, return an empty question. Only ask when you
    genuinely cannot tell, and ask about their business — who uses it, what they
    do with it — never about accounts, tenancy, or architecture.

    If their last answer was not about what they are building, do not follow it
    and do not answer it. Ask your question again, in plain terms. You are here
    to finish their plan and nothing else.
    """
  end

  # ============================================================================
  # Tool
  # ============================================================================

  defp shape_tool do
    Alloy.Tool.inline(
      name: @tool_name,
      description:
        "Submit the next question to ask (empty string if nothing is left worth " <>
          "asking) together with your current best reading of the two generator inputs.",
      input_schema: %{
        type: "object",
        properties: %{
          question: %{
            type: "string",
            description:
              "The one thing still worth asking, phrased the way you would ask a shop " <>
                "owner — never about logins, tenancy, or architecture. Empty string when " <>
                "you can already tell."
          },
          needs_sign_in: %{
            type: "boolean",
            description: "True when people using this have their own account and log in."
          },
          separate_copies: %{
            type: "boolean",
            description:
              "True when many separate businesses would each run their own copy with " <>
                "their own data. False for one business's own tool."
          },
          who_uses: %{
            type: "string",
            description:
              "A few words naming who uses this day to day, in the visitor's own terms."
          }
        },
        required: ["question", "needs_sign_in", "separate_copies", "who_uses"]
      },
      execute: fn _input, _context -> {:ok, "Recorded."} end
    )
  end

  # ============================================================================
  # Reading what the model said
  # ============================================================================

  # At the cap the question is dropped whatever the model did with it, which is
  # what makes the budget a fact rather than a request.
  defp asked(%__MODULE__{turns: turns}, _attrs) when length(turns) >= @max_questions, do: nil

  defp asked(%__MODULE__{}, attrs) do
    case attrs |> Map.get(:question) |> to_string() |> String.trim() do
      "" -> nil
      question -> question
    end
  end

  @schema_fields [:question, :needs_sign_in, :separate_copies, :who_uses]

  defp to_attrs(object) do
    Map.new(@schema_fields, fn field -> {field, field_value(object, field)} end)
  end

  # `false` is an answer, not a missing one.
  #
  # This read `object[to_string(field)] || object[field]`, and two of the four
  # fields are booleans. A model answering `false` — one business's own tool,
  # nobody signs in — hit the `||`, fell through to the atom key, found nothing,
  # and produced `nil`. `answers_changeset/2` then rejected it as blank and the
  # visitor was told the model could not think it through.
  #
  # So it failed on exactly the descriptions that answer no, deterministically,
  # while a multi-tenant idea sailed through. Reported from production as "an ai
  # mahjong coach" failing where "a booking tool for hair salons" worked, which
  # reads as the model being unreliable rather than as `false` being dropped
  # between it and the changeset.
  #
  # `Map.fetch/2` rather than access, because the question is whether the key is
  # there at all.
  defp field_value(object, field) do
    case Map.fetch(object, to_string(field)) do
      {:ok, value} -> value
      :error -> Map.get(object, field)
    end
  end

  defp missing(%{needs_sign_in: sign_in}) when not is_boolean(sign_in), do: "`needs_sign_in`"
  defp missing(_attrs), do: "`separate_copies`"
end
