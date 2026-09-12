defmodule CodeMySpec.Intake.ShaperLlmAlloyTest do
  @moduledoc """
  Two real calls through Alloy, recorded once, replayed by everything else.

  `Shaper.Llm` moved from `ReqLLM.generate_object/4` to `Alloy.run/2` with a
  tool the model must call (`:until_tool`). This is evidence that the move
  actually works end to end — real request, real tool-call shape, real
  response — not a guess about what Alloy's Anthropic provider sends back.

  ## What is recorded, and why these two

  `shaper_asks` — turns are empty, the model can still ask, and a real idea
  ("a booking tool for hair salons") gives it something to ask about. Exercises
  `shape/2`'s `{:ask, question}` branch.

  `shaper_concludes` — turns are at the cap, `conclude/2` is called, and the
  answers already given (sign-in yes, one business's own tool) are pinned
  enough that the model reliably returns them rather than asking anything.
  Exercises the `{:ok, attrs}` branch, including a real recorded `false` for
  `separate_copies` — the exact shape `ShaperFalseAnswerTest` guards the
  mapping for, now proven to be what a real response actually looks like.

  ## To record

      # both cassettes, against the key already in envs/dev.env
      mix test --only record_alloy_turn

  Anthropic, not OpenAI (2026-09-12): a first attempt against
  `Alloy.Provider.OpenAI` hit a transport timeout specific to its completion
  request — reachable by a plain `Req.get/1` to a different endpoint from the
  same runtime, so not a connectivity problem, but a deeper one not worth
  debugging inside a third-party provider for a test. Anthropic is the proven
  path: `AlloyTurnRecorderTest` already records and replays against it, and a
  dev-scoped key already sits in `envs/dev.env` — no production credential
  needed either way. Recording spends real money, a fraction of a cent per
  turn, same price that test already pays.
  """
  use CodeMySpecTest.DataCase, async: false

  import ReqCassette

  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Shaper.Llm

  @cassette_dir "test/cassettes/intake"
  @cassettes ~w(shaper_asks shaper_concludes)
  @model "anthropic:claude-sonnet-5"

  @salon_description "a booking tool for hair salons, my clients book their own slots"
  # Genuinely ambiguous — unlike the salon idea, nothing here tells the model
  # whether people log in or whether this serves one business or many, so a
  # real model has something left to ask about.
  @vague_description "I want a tool to help me keep track of things for my business"

  # `async: false` on the module keeps this test's own cases from racing each
  # other; it does not protect a concurrently-running `async: true` test
  # elsewhere that happens to read the same global config. Restoring both
  # keys on exit is the best isolation available without changing
  # `Shaper.Llm.provider/0` to accept an override as an argument instead of
  # reading `Application.get_env/2` — out of scope for a test of the module
  # as it already exists.
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

  describe "replaying a recorded call" do
    test "shape/2 asks a real question when nothing has been said yet" do
      with_session(fn session ->
        with_cassette("shaper_asks", replay_opts(session), fn plug ->
          configure(plug: plug)

          plan = plan_fixture(@vague_description)

          assert {:ask, question} = Llm.shape(plan, [])
          assert is_binary(question) and question != "",
                 "expected a real question back, got: #{inspect(question)}"
        end)
      end)
    end

    test "conclude/2 reports a real false for separate_copies, not a dropped key" do
      with_session(fn session ->
        with_cassette("shaper_concludes", replay_opts(session), fn plug ->
          configure(plug: plug)

          plan = plan_fixture(@salon_description)

          turns = [
            %{question: "Do your clients log in to book?", answer: "yes, they create an account"},
            %{
              question: "Is this for one salon, or many separate salons each with their own data?",
              answer: "just my one salon"
            }
          ]

          assert {:ok, attrs} = Llm.conclude(plan, turns)

          assert attrs.needs_sign_in == true
          assert attrs.separate_copies == false,
                 "false came back as #{inspect(attrs.separate_copies)} — the exact " <>
                   "shape ShaperFalseAnswerTest guards, now against a real response."

          assert is_binary(attrs.who_uses) and attrs.who_uses != ""
        end)
      end)
    end
  end

  # -- recording --------------------------------------------------------------

  @tag :record_alloy_turn
  @tag timeout: 60_000
  test "records shape/2 asking and conclude/2 concluding" do
    key = anthropic_key()

    for name <- @cassettes, do: File.rm(Path.join(@cassette_dir, name <> ".json"))

    with_session(fn session ->
      with_cassette("shaper_asks", record_opts(session), fn plug ->
        configure(plug: plug, api_key: key)
        plan = plan_fixture(@vague_description)
        assert {:ask, _question} = Llm.shape(plan, [])
      end)
    end)

    with_session(fn session ->
      with_cassette("shaper_concludes", record_opts(session), fn plug ->
        configure(plug: plug, api_key: key)
        plan = plan_fixture(@salon_description)

        turns = [
          %{question: "Do your clients log in to book?", answer: "yes, they create an account"},
          %{
            question:
              "Is this for one salon, or many separate salons each with their own data?",
            answer: "just my one salon"
          }
        ]

        assert {:ok, _attrs} = Llm.conclude(plan, turns)
      end)
    end)

    for name <- @cassettes do
      path = Path.join(@cassette_dir, name <> ".json")
      assert File.exists?(path), "#{name} was not written"

      refute File.read!(path) =~ "sk-ant-",
             "#{name} holds a live credential. The shape is the point; the key must " <>
               "not survive into a committed file."
    end
  end

  # -- helpers ------------------------------------------------------------

  defp plan_fixture(description) do
    {:ok, plan} = Intake.start_plan(Intake.new_session_token())
    {:ok, plan} = Intake.describe(plan, description)
    plan
  end

  # `api_key` defaults to a placeholder in replay — the recorded interaction
  # is matched by method and uri, never by the Authorization header, and
  # `filter_request_headers` below strips it either way before it reaches disk.
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

  defp record_opts(session) do
    [cassette_dir: @cassette_dir, mode: :record] ++ shared_opts(session)
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

  defp anthropic_key do
    System.get_env("ANTHROPIC_API_KEY") || key_from_env_file() ||
      flunk(
        "no Anthropic key. Set ANTHROPIC_API_KEY, or put one in envs/dev.env, " <>
          "which is where this project keeps one."
      )
  end

  defp key_from_env_file, do: parse_key_file(File.read("envs/dev.env"))

  defp parse_key_file({:ok, contents}), do: parse_key(contents)
  defp parse_key_file({:error, _}), do: nil

  defp parse_key(contents) do
    contents
    |> String.split("\n")
    |> Enum.find_value(&key_line_value/1)
  end

  defp key_line_value(line), do: line |> String.split("=", parts: 2) |> value_for_key_line()

  defp value_for_key_line(["ANTHROPIC_API_KEY", value]),
    do: value |> String.trim() |> String.trim("\"") |> presence()

  defp value_for_key_line(_other), do: nil

  defp presence(""), do: nil
  defp presence(value), do: value
end
