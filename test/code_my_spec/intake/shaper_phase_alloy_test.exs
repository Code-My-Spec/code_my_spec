defmodule CodeMySpec.Intake.ShaperPhaseAlloyTest do
  @moduledoc """
  The phase, end to end, on the recordings made for the shaper it replaces.

  `ShaperLlmAlloyTest` records two real calls and asserts what `Shaper.Llm` makes
  of them. This replays the same two files through `Shaper.Phase` and asserts the
  same things, so the two implementations are held to one set of evidence rather
  than each to its own.

  Nothing is recorded here. If these ever need re-recording, do it there — the
  cassettes belong to the call, not to whichever module makes it.
  """
  use CodeMySpecTest.DataCase, async: false

  import ReqCassette

  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Shaper

  @cassette_dir "test/cassettes/intake"
  @model "anthropic:claude-sonnet-5"

  @salon_description "a booking tool for hair salons, my clients book their own slots"
  @vague_description "I want a tool to help me keep track of things for my business"

  @at_cap [
    %{question: "Do your clients log in to book?", answer: "yes, they create an account"},
    %{
      question: "Is this for one salon, or many separate salons each with their own data?",
      answer: "just my one salon"
    }
  ]

  # Same global-config restore as the test this mirrors: `async: false` keeps
  # these cases from racing each other, and putting both keys back on exit is the
  # best isolation available while the impl reads `Application.get_env/2`.
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

  describe "the phase against the recorded calls" do
    test "asks a real question when nothing has been said yet" do
      with_session(fn session ->
        with_cassette("shaper_asks", replay_opts(session), fn plug ->
          configure(plug: plug)

          plan = plan_fixture(@vague_description)

          assert {:ask, question} = Shaper.Phase.shape(plan, [])

          assert is_binary(question) and question != "",
                 "expected a real question back, got: #{inspect(question)}"
        end)
      end)
    end

    test "reports a real false for separate_copies, not a dropped key" do
      with_session(fn session ->
        with_cassette("shaper_concludes", replay_opts(session), fn plug ->
          configure(plug: plug)

          plan = plan_fixture(@salon_description)

          assert {:ok, attrs} = Shaper.Phase.conclude(plan, @at_cap)

          assert attrs.needs_sign_in == true

          assert attrs.separate_copies == false,
                 "false came back as #{inspect(attrs.separate_copies)} — the exact shape " <>
                   "ShaperFalseAnswerTest guards, through the phase this time."

          assert is_binary(attrs.who_uses) and attrs.who_uses != ""
          refute Map.has_key?(attrs, :question)
        end)
      end)
    end

    # The whole point of routing through the config seam: the funnel calls
    # `Shaper.shape/2` and should not be able to tell which implementation ran.
    test "is reachable through the seam the funnel actually calls" do
      with_session(fn session ->
        with_cassette("shaper_concludes", replay_opts(session), fn plug ->
          configure(plug: plug, shaper: Shaper.Phase)

          plan = plan_fixture(@salon_description)

          assert {:ok, attrs} = Shaper.shape(plan, @at_cap)
          assert attrs.separate_copies == false
        end)
      end)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp plan_fixture(description) do
    {:ok, plan} = Intake.start_plan(Intake.new_session_token())
    {:ok, plan} = Intake.describe(plan, description)
    plan
  end

  defp configure(opts) do
    base = [model: @model, req_options: [plug: Keyword.fetch!(opts, :plug)]]

    Application.put_env(
      :code_my_spec,
      CodeMySpec.Intake,
      with_shaper(base, Keyword.fetch(opts, :shaper))
    )

    Application.put_env(:req_llm, :anthropic_api_key, Keyword.get(opts, :api_key, "replayed-key"))
  end

  defp with_shaper(base, {:ok, shaper}), do: Keyword.put(base, :shaper, shaper)
  defp with_shaper(base, :error), do: base

  defp with_session(fun) do
    session = ReqCassette.start_shared_session()
    on_exit(fn -> ReqCassette.end_shared_session(session) end)
    fun.(session)
  end

  defp replay_opts(session) do
    [
      cassette_dir: @cassette_dir,
      mode: :replay,
      sequential: true,
      session: session,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization", "x-api-key"],
      filter_response_headers: ["set-cookie", "request-id"]
    ]
  end
end
