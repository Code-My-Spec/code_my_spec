defmodule CodeMySpecSpex.Story560.Criterion5147Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5147 — sources.md entries include URL, title, and access date.

  ## The criterion's wording is ahead of its rule, deliberately

  The rule is now: every entry names a URL **or** a file path. The date is
  optional. That is the owner's call on issue 1d9bbf6a — "I don't even care
  about the date. I just have the URL or the file path."

  The criterion text still says "URL, title, and access date", so it and this
  spex disagree until story 560 gets a Three Amigos pass to re-word it. Recorded
  here rather than fixed here, because re-wording a criterion is not a change to
  make on the way past.

  Why the rule moved: the checker demanded a URL *and* a date on the same
  physical line, while its message said "URL or date" and the playbook
  documented the format with a URL-less codebase citation that also wrapped. A
  persona's sources are mostly agent definitions, MCP registrations and log
  observations, which have no URL and never will — so following the guide
  produced a file that could not validate, and `orchestrating-main-agent` sat at
  23 failing entries with `personas_complete` unsatisfied.

  Two layers of the contract:

  1. The task prompt enumerates the required entry fields so an
     agent producing artifacts knows what shape they need to take.
  2. The PersonasChecker rejects sources.md files whose entries name
     nothing you can go back to — pure non-empty content does not pass
     (the gap behind issue c5bf0eda, which this rule keeps closed).

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

  spex "a codebase citation with no URL passes the checker" do
    scenario "an entry that names a file path is a source" do
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

      given_ "sources.md cites a file in the repo, with no URL and no date", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            """
            # Sources — Test Persona

            - `CodeMySpec/agents/qa.md` @ a7a0bf53 — declared tool list and
              system prompt for the QA agent.
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
               "a persona's sources are mostly agent definitions, MCP registrations " <>
                 "and log observations, none of which have a URL. Rejecting them " <>
                 "makes the playbook's own example unwritable — issue 1d9bbf6a, " <>
                 "where orchestrating-main-agent sat at 23 failing entries. " <>
                 "Got #{inspect(context.response)}"

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
