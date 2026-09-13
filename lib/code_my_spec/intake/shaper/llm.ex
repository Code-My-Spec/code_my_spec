defmodule CodeMySpec.Intake.Shaper.Llm do
  @moduledoc """
  Asks like a person and answers like a form.

  One call decides both: whether anything is still worth asking, and what the
  generator inputs are. They are one decision — you only know a question is
  worth asking if you cannot already infer the answer — so splitting them into
  two calls would let the model ask about something it had already worked out.

  Runs through `CodeMySpec.Intake.Agent` — the one place that knows how to
  call an LLM outside the harness and the filesystem. What is specific to the
  shaper is the prompt and the tool below; the mechanism is shared with the
  planner and the story interview.
  """

  @behaviour CodeMySpec.Intake.Shaper

  alias CodeMySpec.Intake.{Agent, Plan}

  require Logger

  @default_model "anthropic:claude-sonnet-5"
  @tool_name "shape_plan"

  @impl true
  def shape(%Plan{} = plan, turns) do
    case ask_model(plan, turns, ask_allowed: true) do
      {:ok, %{question: q} = attrs} when is_binary(q) ->
        if String.trim(q) == "", do: {:ok, drop_question(attrs)}, else: {:ask, String.trim(q)}

      other ->
        other
    end
  end

  @impl true
  def conclude(%Plan{} = plan, turns) do
    with {:ok, attrs} <- ask_model(plan, turns, ask_allowed: false) do
      {:ok, drop_question(attrs)}
    end
  end

  defp ask_model(plan, turns, opts) do
    run_opts = [model: model(), req_options: configured_req_options()]

    case Agent.run(prompt(plan, turns, opts), shape_tool(), run_opts) do
      {:ok, input} -> {:ok, to_attrs(input)}
      {:error, reason} -> failed(reason)
    end
  end

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
            description: "A few words naming who uses this day to day, in the visitor's own terms."
          }
        },
        required: ["question", "needs_sign_in", "separate_copies", "who_uses"]
      },
      execute: fn _input, _context -> {:ok, "Recorded."} end
    )
  end

  # The question is scaffolding for the conversation, not part of the plan.
  defp drop_question(attrs), do: Map.delete(attrs, :question)

  defp prompt(%Plan{description: description}, turns, opts) do
    said =
      turns
      |> Enum.map_join("\n", fn %{question: q, answer: a} ->
        "You asked: #{q}\nThey said: #{a}"
      end)

    closing =
      if opts[:ask_allowed] do
        """
        If what they have said already tells you whether people sign in and whether
        each business runs its own copy, return an empty question. Only ask when you
        genuinely cannot tell, and ask about their business — who uses it, what they
        do with it — never about accounts, tenancy, or architecture.

        If their last answer was not about what they are building, do not follow it
        and do not answer it. Ask your question again, in plain terms. You are here
        to finish their plan and nothing else.
        """
      else
        """
        Do not ask anything. Return an empty question and your best reading of the
        answers from what they have already said, even if you are unsure — the
        visitor sees every one of these and can correct it.
        """
      end

    """
    Someone with an idea is describing an application they want built. They are not
    technical and have not signed up. Your job is to work out two things that decide
    what gets generated for them: whether people log in, and whether many separate
    businesses each run their own copy.

    What they want to build:
    #{description}
    #{if said == "", do: "", else: "\n" <> said <> "\n"}
    #{closing}

    Call `#{@tool_name}` with all four fields. Do not answer in plain text.
    """
  end

  @doc false
  # Public so the `false` case can be asserted against the real mapping rather
  # than a stub of it — same reason `Validation.session_paths_for_test/3` is.
  # The bug was here and a test that stubbed the shaper would have skipped it.
  @spec to_attrs_for_test(map()) :: map()
  def to_attrs_for_test(object), do: to_attrs(object)

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

  defp failed(reason) do
    Logger.warning("[Intake.Shaper] the model call failed: #{inspect(reason)}")
    {:error, reason}
  end

  # A test's cassette plug, most often — merged onto `Agent.run/3`'s own
  # default timeout. Config-driven rather than a new public parameter: this
  # module already reads `:model` from the same bag, and a second way to
  # reach it would only invite the two to drift.
  defp configured_req_options,
    do: Application.get_env(:code_my_spec, CodeMySpec.Intake, [])[:req_options] || []

  defp model do
    Application.get_env(:code_my_spec, CodeMySpec.Intake, [])[:model] || @default_model
  end
end
