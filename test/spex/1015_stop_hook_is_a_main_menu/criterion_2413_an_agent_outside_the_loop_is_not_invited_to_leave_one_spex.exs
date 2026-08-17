defmodule CodeMySpecSpex.Story1015.Criterion2413Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2413 — An agent outside the loop is not invited to leave one.

  The rule:

  > A refusal made while the autonomous loop is running offers leaving it.

  The negative half, and the reason this offer is the one exception to
  unconditional. `check_answer`, `ask_user` and `semantic_search` are printed
  every time because what they serve is invisible from here — an unread reply, a
  decision the agent needs, a fact already written down. None of those can be
  detected, so none can be gated.

  `session.continuous` can. And offering `tap_out` outside the loop would be
  worse than noise: it reads as an instruction, the tool would refuse it — its
  whole job is clearing a flag that is not set — and an agent that tried it
  would spend a turn learning that. Three unconditional offers plus one gated on
  a flag is not an inconsistency; it is the difference between what can be known
  and what cannot.

  Paired with 2412 deliberately. On its own, 2412 passes for a response that
  offers `tap_out` always, which is the failure this asserts against.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`. Identical to 2412 except
  that continuous mode is never enabled — this session is an ordinary
  interactive one, which is the common case and the one that must stay quiet.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An interactive agent is not told to quit a loop it is not in" do
    scenario "continuous mode is off and the stop is refused on problems" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a problem is outstanding", context do
        # No `start_continuous_mode` here, and that absence is the scenario.
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())
        {:ok, context}
      end

      when_ "the agent attempts to stop", context do
        response =
          use_cmd_cassette "pipeline_compile_error", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is refused, so there are offers to inspect at all", context do
        # The anchor. Without a refusal the refutation below passes against an
        # empty string and proves nothing.
        assert context.response["decision"] == "block",
               "this scenario needs a refusal for the refutation to mean anything. " <>
                 "Got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "leaving the loop is not offered", context do
        reason = context.response["reason"] || ""

        refute reason =~ "tap_out",
               "there is no loop to leave, and naming the tool reads as an " <>
                 "instruction to use one that would refuse. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "the unconditional offers are still there", context do
        # Proves the refutation above is about `tap_out` specifically rather
        # than about the offers section being absent.
        reason = context.response["reason"] || ""

        assert reason =~ "ask_user"
        assert reason =~ "semantic_search"
        assert reason =~ "check_answer"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp broken_impl do
    """
    defmodule ExampleContext do
      # missing `end`
    """
  end
end
