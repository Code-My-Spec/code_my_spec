defmodule CodeMySpec.Intake.Interviewer.LlmTest do
  @moduledoc """
  `until_tool` only guarantees the model called the named tool, not that its
  input satisfies the tool's own declared `required` schema. This replays a
  real recorded response, edited so the model's `ask_question` call carries
  no `question` key at all — the exact shape that reached `Interview.ask_next/2`
  unguarded and crashed on `intake_interview_turns.question`'s NOT NULL
  constraint instead of being treated as the interview being unavailable
  (918d20e7).

  `interview_missing_question.json` is `interview_recalls_intake_answers.json`'s
  own two tool-call interactions (the question, then the tool result's
  acknowledgement), with the first response's `input` emptied by hand. Real
  recorded shape everywhere else — headers, thinking blocks, usage — so this
  is evidence about the one thing that changed, not a response invented from
  scratch.
  """
  use CodeMySpecTest.DataCase, async: false

  import ReqCassette

  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Interviewer.Llm

  @cassette_dir "test/cassettes/intake"
  @model "anthropic:claude-sonnet-5"

  setup do
    previous_intake = Application.get_env(:code_my_spec, CodeMySpec.Intake, [])
    previous_key = Application.get_env(:req_llm, :anthropic_api_key)

    on_exit(fn ->
      Application.put_env(:code_my_spec, CodeMySpec.Intake, previous_intake)
      restore_anthropic_key(previous_key)
    end)

    :ok
  end

  defp restore_anthropic_key(nil), do: Application.delete_env(:req_llm, :anthropic_api_key)
  defp restore_anthropic_key(value), do: Application.put_env(:req_llm, :anthropic_api_key, value)

  test "a tool call that omits the required field is treated as the interview being unavailable" do
    with_session(fn session ->
      with_cassette("interview_missing_question", replay_opts(session), fn plug ->
        configure(plug: plug)

        plan = plan_fixture("a booking tool for hair salons")

        assert {:error, :interview_unavailable} = Llm.ask(plan, []),
               "a question with no `question` key reached the caller as something " <>
                 "other than the interview being unavailable"
      end)
    end)
  end

  # -- helpers ------------------------------------------------------------

  defp plan_fixture(description) do
    {:ok, plan} = Intake.start_plan(Intake.new_session_token())
    {:ok, plan} = Intake.describe(plan, description)
    plan
  end

  defp configure(opts) do
    Application.put_env(:code_my_spec, CodeMySpec.Intake,
      model: @model,
      req_options: [plug: Keyword.fetch!(opts, :plug)]
    )

    Application.put_env(:req_llm, :anthropic_api_key, Keyword.get(opts, :api_key, "replayed-key"))
  end

  defp with_session(fun) do
    session = ReqCassette.start_shared_session()
    on_exit(fn -> ReqCassette.end_shared_session(session) end)
    fun.(session)
  end

  defp replay_opts(session) do
    [cassette_dir: @cassette_dir, mode: :replay] ++ shared_opts(session)
  end

  defp shared_opts(session) do
    [
      sequential: true,
      session: session,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization", "x-api-key"],
      filter_response_headers: ["set-cookie", "request-id"]
    ]
  end
end
