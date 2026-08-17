defmodule CodeMySpecSpex.Story1012.Criterion2347Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 2347 — The suffix does not tax the turn.

  Rule: The check that decides whether to speak is cheap enough to run on every
  tool call.

  Delivery rides on every Read, Grep, Bash and MCP call in the system, for a
  message that fires once or twice a turn. If deciding to stay silent costs a
  problems query, every tool call in every session pays for it.

  This is a rule rather than an implementation note because getting it wrong
  does not produce a bug — it produces a mechanism people switch off. A gate
  that makes everything feel slow gets disabled, and then the signal is gone
  again, which is where `split_unattributed` ended up by a different route.

  Measured in queries rather than milliseconds: wall-clock on a loaded machine
  is noise, and the property is about what the check *does*, not how fast the
  box is.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Silence is cheap" do
    scenario "The suffix does not tax the turn" do
      given_ :synced_context_component

      given_ "the working copy holds findings the agent has already been told about",
             context do
        session = "spex-busy-#{System.unique_integer([:positive])}"

        use_cmd_cassette "pipeline_exunit_failure", record: :none do
          post_hook(context, "/api/hooks/stop", %{
            "session_id" => "spex-seed-#{System.unique_integer([:positive])}",
            "test_output_files" => %{
              "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
              "compile" => Path.expand(Path.join(@fixture_dir, "compile.jsonl")),
              "exunit" => Path.expand(Path.join(@fixture_dir, "exunit.json"))
            }
          })
        end

        post_hook(context, "/api/hooks/post-tool-use", tool_call(session))

        {:ok, Map.put(context, :session, session)}
      end

      when_ "the agent makes many tool calls and no analyzer run has landed", context do
        # Count the repo queries the hook issues while it has nothing to say.
        # Telemetry rather than timing: the claim is about work done, and a
        # stopwatch on a machine running four agents measures the machine.
        handler = {__MODULE__, make_ref()}
        counter = :counters.new(1, [:atomics])

        :telemetry.attach(
          handler,
          [:code_my_spec, :repo, :query],
          fn _event, _measure, _meta, _config -> :counters.add(counter, 1, 1) end,
          nil
        )

        calls = 10

        # Measured as a difference, not a total. The hook does its own work —
        # session lookup, touch, edit tracking — and charging that to this rule
        # would assert something about PostToolUse rather than about the check.
        # A call with no session short-circuits the check entirely, so the gap
        # between the two IS the check's cost.
        for _ <- 1..calls, do: post_hook(context, "/api/hooks/post-tool-use", tool_call(nil))
        baseline = :counters.get(counter, 1)

        for _ <- 1..calls,
            do: post_hook(context, "/api/hooks/post-tool-use", tool_call(context.session))

        with_check = :counters.get(counter, 1) - baseline
        :telemetry.detach(handler)

        {:ok,
         context
         |> Map.put(:added, with_check - baseline)
         |> Map.put(:calls, calls)}
      end

      then_ "deciding to stay silent costs a single cheap read per call", context do
        per_call = context.added / context.calls

        # The bound is 2, not 1, and the extra one is not slack. A session-less
        # call also skips `mark_active`'s session lookup and touch, so this
        # difference carries the alert's watermark AND that bookkeeping. One
        # query of the two is the check; the other belongs to the hook and
        # predates this story. Isolating further would need a flag on the hook,
        # which is a worse thing to own than a documented +1.
        assert per_call <= 2.0,
               "the check added #{Float.round(per_call, 1)} queries per tool call " <>
                 "(#{context.added} across #{context.calls}), where at most one of " <>
                 "those is session bookkeeping the hook already did. This runs before " <>
                 "every Read, Grep and Bash in the system for a message that fires " <>
                 "twice a turn — at that price it is a mechanism someone switches off, " <>
                 "and a disabled gate ends where split_unattributed ended."

        {:ok, context}
      end
    end
  end

  defp tool_call(nil) do
    %{"tool_name" => "Read", "tool_input" => %{"file_path" => "lib/example_context.ex"}}
  end

  defp tool_call(session_id) do
    %{
      "session_id" => session_id,
      "tool_name" => "Read",
      "tool_input" => %{"file_path" => "lib/example_context.ex"}
    }
  end
end
