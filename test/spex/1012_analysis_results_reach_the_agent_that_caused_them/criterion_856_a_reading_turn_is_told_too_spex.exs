defmodule CodeMySpecSpex.Story1012.Criterion2343Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 2343 — A reading turn is told too.

  Rule: A completed analyzer run reaches the agent on its next tool call,
  whatever that call is.

  Scoping delivery to edits would reintroduce a "which tools count" judgement,
  which is the same species of question as "which files count" — and that one
  turned the stop gate into a no-op. It would also go silent through exactly the
  stretches where an agent is reasoning about what it just did rather than
  typing, which is when a landed result is most worth having.

  The incident supports it directly: the file edited (`story.ex`) was nowhere
  near the four stories whose spex broke.

  Surface: the PostToolUse hook on a read.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.HarnessHooks

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every tool call carries it, not only the ones that write", criterion: 856 do
    scenario "A reading turn is told too" do
      given_ :synced_context_component

      given_ "an agent is reading rather than editing", context do
        {:ok, Map.put(context, :session, "spex-reader-#{System.unique_integer([:positive])}")}
      end

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      when_ "an analyzer run completes", context do
        HarnessHooks.land_analysis(
          context,
          "spex",
          Path.expand("test/fixtures/validation/spex_green.jsonl")
        )

        HarnessHooks.land_analysis(
          context,
          "compiler",
          Path.expand(Path.join(@fixture_dir, "compile.jsonl"))
        )

        HarnessHooks.land_analysis(
          context,
          "exunit",
          Path.expand(Path.join(@fixture_dir, "exunit.json"))
        )

        HarnessHooks.post_hook(context, "stop", %{
          "session_id" => "spex-other-#{System.unique_integer([:positive])}"
        })

        {:ok, context}
      end

      then_ "the agent is told on its next tool call", context do
        told =
          post_hook(context, "/api/hooks/post-tool-use", %{
            "session_id" => context.session,
            "tool_name" => "Read",
            "tool_input" => %{"file_path" => "lib/example_context.ex"}
          })

        assert (told["systemMessage"] || "") =~ "exunit",
               "a reading turn was told nothing. An agent that spends a stretch reading " <>
                 "is reasoning about what it just did, which is when a landed result is " <>
                 "most worth having. Got: #{inspect(told)}"

        {:ok, context}
      end

      then_ "the call being a read rather than a write makes no difference", context do
        # Same result, different tool. If these two ever disagree there is a
        # "which tools count" rule in the delivery path, and that is a place a
        # finding can hide.
        grep =
          post_hook(context, "/api/hooks/post-tool-use", %{
            "session_id" => "spex-grepper-#{System.unique_integer([:positive])}",
            "tool_name" => "Grep",
            "tool_input" => %{"pattern" => "defmodule"}
          })

        assert (grep["systemMessage"] || "") =~ "exunit",
               "a Grep was treated differently from a Read. Whichever tool is the " <>
                 "exception becomes the blind spot. Got: #{inspect(grep)}"

        {:ok, context}
      end
    end
  end
end
