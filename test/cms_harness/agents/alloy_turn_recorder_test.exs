defmodule CmsHarness.Agents.AlloyTurnRecorderTest do
  @moduledoc """
  One real turn, recorded once, replayed by everything that needs one.

  Recording and consuming are deliberately different tests. The devops
  cassettes were recorded as a side effect of whatever ran last, which is how a
  cassette ends up holding a failure nobody meant to capture — and `:record`
  replays on a match rather than re-recording, so once a bad response is in
  there every later run replays it and it reads as a provider outage.

  So this file records specific, named situations and nothing else does. The
  recorder is tagged out of the default suite and refuses to run without a
  credential; the replay below runs in every suite and is what actually asserts
  something.

  ## What is recorded, and why these two

  `alloy_turn_answer` — a question and a reply. The ordinary turn, and the one
  the transcript's `:message` event is derived from.

  `alloy_turn_reads_a_file` — a turn that uses a tool. Its shape is the one that
  breaks differently: a `tool_use` block, a second request carrying the result,
  and only then the text. Every step of it reaches the operator's transcript
  separately, so a change in that shape is a change in what somebody watching
  sees.

  ## To record

      # both cassettes, against the key already in envs/dev.env
      mix test --only record_alloy_turn

  A key in `ANTHROPIC_API_KEY` wins; otherwise `envs/dev.env` is read, which is
  where this project keeps one. Anthropic rather than `openai-codex` because
  `codex exec` is a subprocess — there is no Req client to record — and
  `Alloy.Provider.Anthropic` passes `:req_options` straight through to Req in
  both `complete/3` and `stream/4`.

  Recording spends real money, a fraction of a cent per turn. That is the price
  of a recording that is evidence rather than a guess about a wire format.
  """
  use ExUnit.Case, async: false

  import ReqCassette

  alias CmsHarnessTest.Machine

  @moduletag :tmp_dir

  @cassette_dir "test/cassettes/alloy"

  # What the agent is asked, and a word only the answer can contain. Recorded
  # deliberately: an assertion on "ok" or on a word the prompt already uses
  # matches the request being echoed back in the cassette, and passes whether or
  # not the model ever answered.
  @question "Reply with exactly the word PROVIDER-ANSWERED and nothing else."
  @answer "PROVIDER-ANSWERED"

  @file_name "pricing.txt"
  @file_body "the plan charges per seat"

  setup %{tmp_dir: tmp_dir} do
    Machine.ensure_supervisor()
    File.write!(Path.join(tmp_dir, @file_name), @file_body <> "\n")
    %{root: tmp_dir}
  end

  describe "replaying a recorded turn" do
    test "an answer reaches the operator as a message", %{root: root} do
      events = record_events()

      with_session(fn session ->
        with_cassette "alloy_turn_answer", replay_opts(session), fn plug ->
          agent = start_agent(root, plug, events)
          {:ok, _} = Machine.send_message(agent, "ref-1", @question)
          Machine.await_idle(agent)
        end
      end)

      assert Enum.any?(collected(events), fn event ->
               event[:event] == :message and String.contains?(event[:text] || "", @answer)
             end),
             "the turn ran and nothing reached the transcript as a message. Providers " <>
               "emit fragments and say nothing at completion, so the answer exists only " <>
               "as tokens the engine drops unless it announces the outcome itself."
    end

    test "a turn that uses a tool reports the call, then the answer it produced",
         %{root: root} do
      events = record_events()

      with_session(fn session ->
        with_cassette "alloy_turn_reads_a_file", replay_opts(session), fn plug ->
          agent = start_agent(root, plug, events)

          {:ok, _} =
            Machine.send_message(
              agent,
              "ref-1",
              "Read #{@file_name} in the working directory and tell me what it says."
            )

          Machine.await_idle(agent)
        end
      end)

      steps = collected(events)
      kinds = Enum.map(steps, & &1[:event])

      assert Enum.find(steps, &(&1[:event] == :tool_start)),
             "the agent answered without reading anything. The recording holds a real " <>
               "`read` call, so a replay that produces no tool step means the engine is " <>
               "not acting on what the provider asked for."

      call = Enum.find(steps, &(&1[:event] == :tool_start))
      assert call.payload.name == "read"
      assert call.payload.input["file_path"] == @file_name

      assert Enum.find_index(kinds, &(&1 == :tool_start)) <
               Enum.find_index(kinds, &(&1 == :message)),
             "the answer reached the transcript before the call it was based on. " <>
               "Somebody watching sees the conclusion and then the working, which is " <>
               "the opposite of watching."

      answer = Enum.find(steps, &(&1[:event] == :message))

      assert answer.text =~ @file_body,
             "the answer does not contain what the file says. The agent is answering " <>
               "about the code that is actually in the checkout, or it is not — and " <>
               "this is the difference."

      # Both fragment kinds. `text_delta` was already dropped; `thinking_delta`
      # was not, and a real recorded turn is what showed one arriving.
      refute Enum.any?(kinds, &(&1 in [:text_delta, :thinking_delta])),
             "token fragments reached the transcript. Alloy emits one per few " <>
               "characters, and forwarding them puts a channel push and a database row " <>
               "behind each — which is how a sentence became forty rows."
    end
  end

  # -- recording ------------------------------------------------------------

  @tag :record_alloy_turn
  @tag timeout: 180_000
  test "records a plain answer and a tool-using turn", %{root: root} do
    key = anthropic_key()
    events = record_events()

    with_session(fn session ->
      with_cassette "alloy_turn_answer", record_opts(session), fn plug ->
        agent = start_agent(root, plug, events, api_key: key)
        {:ok, _} = Machine.send_message(agent, "ref-1", @question)
        Machine.await_idle(agent)
      end
    end)

    with_session(fn session ->
      with_cassette "alloy_turn_reads_a_file", record_opts(session), fn plug ->
        agent = start_agent(root, plug, events, api_key: key)

        {:ok, _} =
          Machine.send_message(
            agent,
            "ref-1",
            "Read #{@file_name} in the working directory and tell me what it says."
          )

        Machine.await_idle(agent)
      end
    end)

    for name <- ~w(alloy_turn_answer alloy_turn_reads_a_file) do
      path = Path.join(@cassette_dir, name <> ".json")

      assert File.exists?(path), "#{name} was not written"

      contents = File.read!(path)

      refute contents =~ "sk-ant-",
             "#{name} holds a live credential. The shape is the point; the key must " <>
               "not survive into a committed file."
    end

    # The tool-using cassette has to hold the whole loop, not its first request.
    # It held one interaction the first time this ran — the model called the
    # tool, and the follow-up request carrying the result matched the first by
    # method and uri and was replayed instead of recorded. A cassette that stops
    # at `tool_use` answers "call a tool" to every request forever.
    interactions =
      @cassette_dir
      |> Path.join("alloy_turn_reads_a_file.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("interactions")

    assert length(interactions) >= 2,
           "the tool-using recording holds #{length(interactions)} interaction(s). A " <>
             "turn that calls a tool makes at least two requests: the one that decides " <>
             "to call it, and the one carrying its result."
  end

  # -- the agent ------------------------------------------------------------

  # A real engine turn, not a call to Alloy. The recording is evidence about
  # what this harness does with a provider's answer, and a turn driven straight
  # at Alloy would be evidence about Alloy.
  defp start_agent(root, plug, events, opts \\ []) do
    id = "alloy-recorder-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Machine.start_agent(id, root,
        provider: "anthropic",
        api_key: Keyword.get(opts, :api_key, "recorded-key"),
        req_options: [plug: plug],
        on_event: fn _agent_id, envelope -> Agent.update(events, &[envelope | &1]) end
      )

    on_exit(fn -> Machine.stop_agent(id) end)

    id
  end

  defp record_events do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    pid
  end

  defp collected(events), do: events |> Agent.get(& &1) |> Enum.reverse()

  # -- cassettes ------------------------------------------------------------

  defp replay_opts(session) do
    [cassette_dir: @cassette_dir, mode: :replay] ++ shared_opts(session)
  end

  defp record_opts(session) do
    [cassette_dir: @cassette_dir, mode: :record] ++ shared_opts(session)
  end

  # Sequential, and matched on method and uri only.
  #
  # Every request an agent loop makes goes to the same URL, so matching on
  # method and uri alone cannot tell the first from the second — and `:record`
  # replays on a match rather than recording again. That silently turned a
  # two-request turn into a one-interaction cassette that answers `tool_use`
  # to every request forever.
  #
  # Matching on the body instead would fix the ambiguity and make the recording
  # single-use: a turn's body carries the working directory, which is a fresh
  # temp path every run, and the tool manifest, which changes whenever a tool is
  # added. Sequential gives request N interaction N, which is what a loop
  # actually is.
  #
  # The session is not optional here. The turn runs in a `Task` inside the
  # engine and the provider call is in another process again, so the process
  # dictionary sequential matching normally uses reaches neither.
  defp shared_opts(session) do
    [
      sequential: true,
      session: session,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["x-api-key", "authorization"],
      filter_response_headers: ["set-cookie", "request-id"]
    ]
  end

  # A shared session for one cassette, ended whatever happens.
  defp with_session(fun) do
    session = ReqCassette.start_shared_session()

    try do
      fun.(session)
    after
      ReqCassette.end_shared_session(session)
    end
  end

  # The key, from the environment or from where this project keeps one.
  #
  # Read from `envs/dev.env` directly rather than through Dotenvy: this test is
  # the only reader, it runs under `MIX_ENV=test` where that file is not loaded,
  # and asking somebody to export a variable that is already sitting in the repo
  # is how a recorder goes un-run.
  defp anthropic_key do
    System.get_env("ANTHROPIC_API_KEY") || key_from_env_file() ||
      flunk(
        "no Anthropic key. Set ANTHROPIC_API_KEY, or put one in envs/dev.env, " <>
          "which is where this project keeps one."
      )
  end

  defp key_from_env_file do
    case File.read("envs/dev.env") do
      {:ok, contents} -> parse_key(contents)
      {:error, _} -> nil
    end
  end

  defp parse_key(contents) do
    contents
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, "=", parts: 2) do
        ["ANTHROPIC_API_KEY", value] -> value |> String.trim() |> String.trim("\"") |> presence()
        _ -> nil
      end
    end)
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
