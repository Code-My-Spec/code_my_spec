defmodule CodeMySpecSpex.Story560.Criterion5147Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5147 — sources.md entries include URL, title, and access date.

  Two layers of the contract:

  1. The task prompt enumerates the required entry fields so an
     agent producing artifacts knows what shape they need to take.
  2. The PersonasChecker rejects sources.md files whose entries are
     missing a URL or a YYYY-MM-DD access date — pure non-empty
     content no longer passes (was the gap behind issue c5bf0eda).

  Surface: the stop-hook pipeline via EvaluateTask. Each scenario
  writes artifacts and calls evaluate_task; the response text carries
  whether the checker accepted or rejected the sources.md content.

  Each enforcement scenario lives in its own `spex` block so it gets
  a fresh ExUnit sandbox — SexySpex runs scenarios sequentially inside
  one `spex`, with no rollback between them, so `:persona_exists` would
  accumulate state across scenarios.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "prompt specifies sources.md entry format" do
    scenario "prompt lists URL, title, and access date as required fields" do
      given_ :persona_research_prompt

      then_ "the prompt enumerates URL + title + access date", context do
        assert context.prompt =~ ~r/URL/
        assert context.prompt =~ ~r/title/i
        assert context.prompt =~ ~r/access date|accessed/i

        {:ok, context}
      end
    end
  end

  spex "well-formed sources.md passes the checker" do
    scenario "well-formed entries with URL + title + ISO date pass the checker" do
      given_ :persona_exists
      given_ :persona_research_task_started

      given_ "summary.md is written with all required sections", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            minimal_persona_summary()
          )

        {:ok, context}
      end

      given_ "sources.md has well-formed entries with URL + title + date", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            """
            # Sources — Test Persona

            - https://example.com/article — "Article Title" — accessed 2026-05-18
            - https://example.org/research — "Research Paper" — accessed 2026-05-17
            """
          )

        {:ok, context}
      end

      when_ "the agent calls evaluate_task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the evaluate response is a pass", context do
        body = response_text(context.response)

        assert body =~ ~r/pass|complete|satisfied|done/i,
               "expected a passing evaluate response for well-formed sources.md; got #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  spex "sources.md entry missing URL fails the checker" do
    scenario "sources.md with entries missing a URL fails the checker" do
      given_ :persona_exists
      given_ :persona_research_task_started

      given_ "summary.md is written with all required sections", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            minimal_persona_summary()
          )

        {:ok, context}
      end

      given_ "sources.md has an entry with no URL", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            """
            # Sources — Test Persona

            - "Article Title" — accessed 2026-05-18
            """
          )

        {:ok, context}
      end

      when_ "the agent calls evaluate_task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the feedback names sources.md and the URL or date gap", context do
        body = response_text(context.response)

        assert body =~ ~r/Needs work|incomplete|missing|invalid/i,
               "expected blocking feedback for missing URL; got #{inspect(context.response)}"

        assert body =~ ~r/sources\.md/i,
               "expected feedback to name sources.md"

        assert body =~ ~r/url|date/i,
               "expected feedback to name the URL-or-date gap"

        {:ok, context}
      end
    end
  end

  spex "sources.md entry missing date fails the checker" do
    scenario "sources.md with entries missing an access date fails the checker" do
      given_ :persona_exists
      given_ :persona_research_task_started

      given_ "summary.md is written with all required sections", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            minimal_persona_summary()
          )

        {:ok, context}
      end

      given_ "sources.md has an entry with no date", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            """
            # Sources — Test Persona

            - https://example.com/article — "Article Title" — (no date)
            """
          )

        {:ok, context}
      end

      when_ "the agent calls evaluate_task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the feedback names sources.md and the URL or date gap", context do
        body = response_text(context.response)

        assert body =~ ~r/Needs work|incomplete|missing|invalid/i,
               "expected blocking feedback for missing date; got #{inspect(context.response)}"

        assert body =~ ~r/sources\.md/i,
               "expected feedback to name sources.md"

        assert body =~ ~r/url|date/i,
               "expected feedback to name the URL-or-date gap"

        {:ok, context}
      end
    end
  end

  spex "sources.md with no list entries fails the checker" do
    scenario "sources.md with no markdown list entries fails the checker" do
      given_ :persona_exists
      given_ :persona_research_task_started

      given_ "summary.md is written with all required sections", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            minimal_persona_summary()
          )

        {:ok, context}
      end

      given_ "sources.md has only prose, no list items", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            """
            # Sources — Test Persona

            Just some plain text without bullet list entries.
            """
          )

        {:ok, context}
      end

      when_ "the agent calls evaluate_task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the feedback names sources.md and the missing entries", context do
        body = response_text(context.response)

        assert body =~ ~r/Needs work|incomplete|missing|invalid/i,
               "expected blocking feedback for no list entries; got #{inspect(context.response)}"

        assert body =~ ~r/sources\.md/i,
               "expected feedback to name sources.md"

        assert body =~ ~r/no entries|missing|url|date/i,
               "expected feedback to name the no-entries or format gap"

        {:ok, context}
      end
    end
  end

  defp minimal_persona_summary do
    """
    # Founder

    ## Role
    Solo founder building a product without hiring a team.

    ## Goals
    Ship features continuously without losing context between product and code.

    ## Pain Points
    Context-switching across product, engineering, and marketing burns the week.

    ## Context
    One-person team, limited budget, weekly release cadence.

    ## Decision Drivers
    Speed-to-ship and autonomy dominate polish.

    ## Evidence
    Internal notes; customer interviews pending.
    """
  end
end
