defmodule CodeMySpecSpex.Story1158.Criterion2468Spex do
  @moduledoc """
  Story 1158 — QA plans and briefs are documents in the database, not files in the docs submodule.
  Criterion 2468 — A QA agent writes a story brief and the next attempt reads it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Later QA attempts update the story's single brief document", criterion: 2468 do
    scenario "the next attempt reads an updated brief without a brief.md file" do
      given_ "a QA agent is starting QA on a story", context do
        later_scope = Fixtures.live_agent_scope(context.scope, label: "Later QA attempt")
        {:ok, Map.put(context, :later_scope, later_scope)}
      end

      when_ "the agent writes the story brief and a later attempt updates it through document tools",
            context do
        first =
          ToolLibrary.run(
            "write_document",
            %{
              document_type: "qa_story_brief",
              story_number: context.story.number,
              content: brief("Check sign-in")
            },
            %{current_scope: context.scope, scope: context.scope}
          )

        refute first.isError, response_text(first)

        updated =
          ToolLibrary.run(
            "write_document",
            %{
              document_type: "qa_story_brief",
              story_number: context.story.number,
              content: brief("Check sign-in and sign-out")
            },
            %{current_scope: context.later_scope, scope: context.later_scope}
          )

        refute updated.isError, response_text(updated)
        {:ok, context}
      end

      then_ "the story has the updated brief and no brief.md under .code_my_spec/qa",
            context do
        response =
          ToolLibrary.run(
            "read_document",
            %{document_type: "qa_story_brief", story_number: context.story.number},
            %{current_scope: context.scope, scope: context.scope}
          )

        refute response.isError, response_text(response)
        text = response_text(response)
        assert text =~ "Check sign-in and sign-out"
        refute text =~ "Check sign-in\n"

        brief_path = ".code_my_spec/qa/#{context.story.number}/brief.md"
        refute ExecutionContexts.file_exists?(context.execution_context, brief_path)
        {:ok, context}
      end
    end
  end

  defp brief(test_step) do
    """
    # QA Story Brief

    ## Tool

    web

    ## Auth

    Sign in with the seeded QA account.

    ## Seeds

    Use the seeded QA account and project.

    ## What to Test

    - #{test_step}.

    ## Result Path

    .code_my_spec/qa/results.md
    """
  end
end
