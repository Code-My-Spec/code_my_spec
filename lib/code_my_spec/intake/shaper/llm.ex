defmodule CodeMySpec.Intake.Shaper.Llm do
  @moduledoc """
  Asks like a person and answers like a form.

  One call decides both: whether anything is still worth asking, and what the
  generator inputs are. They are one decision — you only know a question is
  worth asking if you cannot already infer the answer — so splitting them into
  two calls would let the model ask about something it had already worked out.
  """

  @behaviour CodeMySpec.Intake.Shaper

  alias CodeMySpec.Intake.Plan

  require Logger

  @default_model "anthropic:claude-sonnet-5"

  @schema [
    question: [
      type: :string,
      required: true,
      doc:
        "The one thing still worth asking, phrased the way you would ask a shop owner — never about logins, tenancy, or architecture. Empty string when you can already tell."
    ],
    needs_sign_in: [
      type: :boolean,
      required: true,
      doc: "True when people using this have their own account and log in."
    ],
    separate_copies: [
      type: :boolean,
      required: true,
      doc:
        "True when many separate businesses would each run their own copy with their own data. False for one business's own tool."
    ],
    who_uses: [
      type: :string,
      required: true,
      doc: "A few words naming who uses this day to day, in the visitor's own terms."
    ]
  ]

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
    # A timeout the model can actually finish inside.
    #
    # Req defaults `receive_timeout` to 15s and this set none, which is a budget
    # that fits a fast chat model and nothing else. Measured against the same
    # turn: gpt-4o answers in 2.2s and gpt-5 in 15.0s — right on the line
    # locally, and reliably over it from a Fly region. So the conversation
    # worked or did not depending on which side of 15s the model landed, which
    # reads as the model being broken rather than the caller being impatient.
    #
    # 120s because the visitor is watching a "Thinking…" bubble and would rather
    # wait than be told to start again; a model that has not answered by then is
    # genuinely wrong, not slow.
    case ReqLLM.generate_object(model(), prompt(plan, turns, opts), @schema,
           temperature: 0.2,
           receive_timeout: to_timeout(second: 120)
         ) do
      {:ok, response} -> {:ok, response |> ReqLLM.Response.object() |> to_attrs()}
      {:error, reason} -> failed(reason)
    end
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
    """
  end

  defp to_attrs(object) do
    Map.new(@schema, fn {field, _spec} ->
      {field, object[to_string(field)] || object[field]}
    end)
  end

  defp failed(reason) do
    Logger.warning("[Intake.Shaper] the model call failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp model do
    Application.get_env(:code_my_spec, CodeMySpec.Intake, [])[:model] || @default_model
  end
end
