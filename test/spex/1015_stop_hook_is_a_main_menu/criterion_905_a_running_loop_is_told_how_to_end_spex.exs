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
  alias CodeMySpecSpex.HarnessHooks

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent in the loop is shown the door", criterion: 905 do
    scenario "continuous mode is on and the stop is refused on problems" do
      given_ :synced_context_component
      given_ :context_implementation_task_started

      given_ "the autonomous loop is running", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)
        {:ok, context}
      end

      given_ "a problem is outstanding", context do
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())
        :ok = record_edit(context, @impl_path)
        {:ok, context}
      end

      when_ "the agent attempts to stop", context do
        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))

        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "leaving the loop is not offered by the refusal that holds it in", context do
        reason = context.response["reason"] || ""

        # A refusal is not the place for the exit (`227d1595`). This very
        # response is what is keeping the agent in the loop; telling it to ask
        # to leave is the offer John removed for the empty queue, and it is no
        # more coherent here. `tap_out` exits continuous mode, so an agent that
        # took the offer here would have to be re-staffed by hand before the
        # problems it is being held on could be fixed. The offer still reaches
        # an agent with work in front of it, through the menu's own paths.
        refute reason =~ "asks to leave it",
               "the refusal holds the agent in the loop and must not then invite " <>
                 "it to leave. Got:\n#{reason}"

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
