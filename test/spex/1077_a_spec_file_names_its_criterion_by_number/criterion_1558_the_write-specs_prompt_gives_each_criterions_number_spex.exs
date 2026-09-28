defmodule CodeMySpecSpex.Story1077.Criterion4682Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4682 — The write-specs prompt gives each criterion's number.

  Covers Rule "The agent writing specs is told each criterion's number".
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The prompt says what to put on each spex call", criterion: 1558 do
    scenario "the agent starts a write-specs task on a story with two criteria" do
      given_ :synced_context_component

      given_ "the story has two criteria", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Two things",
            description: "A story that needs specs.",
            acceptance_criteria: ["The first thing happens", "The second thing happens"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      # `:bdd_task_started` is the agent's start_task call, through the real
      # session-start hook and StartTask tool; the prompt it returns is what is
      # under test.
      given_ :bdd_task_started

      when_ "the agent reads the prompt its write-specs task handed it", context do
        {:ok, Map.put(context, :handed, context.prompt)}
      end

      then_ "the prompt shows criterion: N as the line for each spex call", context do
        prompt = context.handed

        for criterion <- context.story.criteria do
          assert prompt =~ "criterion: #{criterion.id}",
                 "the prompt should give `criterion: #{criterion.id}` for the spex call. Got:\n" <>
                   String.slice(prompt, 0, 3000)
        end

        {:ok, context}
      end
    end
  end
end
