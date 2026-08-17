defmodule CodeMySpecSpex.Story1015.Criterion2412Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2412 — A running loop is told how to end.

  The rule:

  > A refusal made while the autonomous loop is running offers leaving it.

  ## The gap this closes

  Two loops exist and both already have escapes. Continuous mode is turned on by
  `StartImplementation.init_session/2` setting `session.continuous`, and left via
  `tap_out`, which publishes a permission request and clears the flag on
  approval. Problem-blocking is escaped by fixing the findings, or by R8's
  stuck detection force-allowing after `@stuck_threshold` identical blocks.

  Neither escape was ever mentioned to the agent. The continuous-mode refusal
  read "Continuing the autonomous loop with the next assignment" and stopped
  there — so an agent burning tokens in a loop had a tool for exactly that and
  no way to learn it existed. John: "the thing I want to avoid is having this
  infinite stop hook that's just firing over and over again and wasting tokens
  with the model, so it has to be able to tap out and quit the loop."

  ## Conditional, and why that is still an offer

  The other three offers are unconditional because what they serve is invisible
  from here. This one is shown only inside the loop — and that does not break
  the split, because `session.continuous` is a flag, as detectable as a row.
  What makes it an offer rather than a class is that leaving the loop is not
  work: it cannot be ranked against problems and must not take the directive.

  Criterion 2413 asserts the other half — that an agent outside the loop is not
  invited to leave one, which would read as an instruction to use a tool that
  would refuse it.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`, with continuous mode
  enabled through the same fixture the autonomous-loop story uses, and a genuine
  compile failure so the stop is refused on a class rather than on the loop.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent in the loop is shown the door" do
    scenario "continuous mode is on and the stop is refused on problems" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "the autonomous loop is running", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)
        {:ok, context}
      end

      given_ "a problem is outstanding", context do
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

      then_ "leaving the loop is offered", context do
        reason = context.response["reason"] || ""

        assert reason =~ "tap_out",
               "an agent burning tokens in a loop has a tool for exactly that, " <>
                 "and no way to learn it exists unless the refusal says so. " <>
                 "Got:\n#{reason}"

        {:ok, context}
      end

      then_ "leaving the loop is not the directive", context do
        reason = context.response["reason"] || ""
        next_lines = reason |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/\bnext\b/i))

        refute Enum.any?(next_lines, &(&1 =~ "tap_out")),
               "quitting is not work and must not be ranked against work. " <>
                 "Got:\n#{Enum.join(next_lines, "\n")}"

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
