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
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.PersonasRepository
  alias CodeMySpec.Requirements.PersonasChecker

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

  spex "PersonasChecker enforces sources.md entry format" do
    scenario "well-formed entries with URL + title + ISO date pass the checker" do
      given_ "a persona DB row and well-formed sources.md + summary.md on disk",
             context do
        write_persona_artifacts(context, """
        # Sources — Test Persona

        - https://example.com/article — "Article Title" — accessed 2026-05-18
        - https://example.org/research — "Research Paper" — accessed 2026-05-17
        """)

        {:ok, context}
      end

      when_ "the checker evaluates the persona", context do
        result = PersonasChecker.complete?(context.scope, context.scope.active_project)
        {:ok, Map.put(context, :result, result)}
      end

      then_ "the result is satisfied", context do
        assert {true, _details} = context.result
        {:ok, context}
      end
    end

    scenario "sources.md with entries missing a URL fails the checker" do
      given_ "a persona DB row and a sources.md whose entry has no URL",
             context do
        write_persona_artifacts(context, """
        # Sources — Test Persona

        - "Article Title" — accessed 2026-05-18
        """)

        {:ok, context}
      end

      when_ "the checker evaluates the persona", context do
        result = PersonasChecker.complete?(context.scope, context.scope.active_project)
        {:ok, Map.put(context, :result, result)}
      end

      then_ "the result is unsatisfied with a URL-or-date gap message", context do
        assert {false, details} = context.result

        assert details.reason =~ ~r/sources\.md/i
        assert details.reason =~ ~r/url|date/i

        {:ok, context}
      end
    end

    scenario "sources.md with entries missing an access date fails the checker" do
      given_ "a persona DB row and a sources.md whose entry has no date",
             context do
        write_persona_artifacts(context, """
        # Sources — Test Persona

        - https://example.com/article — "Article Title" — (no date)
        """)

        {:ok, context}
      end

      when_ "the checker evaluates the persona", context do
        result = PersonasChecker.complete?(context.scope, context.scope.active_project)
        {:ok, Map.put(context, :result, result)}
      end

      then_ "the result is unsatisfied with a URL-or-date gap message", context do
        assert {false, details} = context.result

        assert details.reason =~ ~r/sources\.md/i
        assert details.reason =~ ~r/url|date/i

        {:ok, context}
      end
    end

    scenario "sources.md with no markdown list entries fails the checker" do
      given_ "a persona DB row and a sources.md with only prose, no list items",
             context do
        write_persona_artifacts(context, """
        # Sources — Test Persona

        Just some plain text without bullet list entries.
        """)

        {:ok, context}
      end

      when_ "the checker evaluates the persona", context do
        result = PersonasChecker.complete?(context.scope, context.scope.active_project)
        {:ok, Map.put(context, :result, result)}
      end

      then_ "the result is unsatisfied with a no-entries gap message", context do
        assert {false, details} = context.result

        assert details.reason =~ ~r/sources\.md/i
        assert details.reason =~ ~r/no entries|missing/i

        {:ok, context}
      end
    end
  end

  defp write_persona_artifacts(context, sources_content) do
    slug = "test-persona-#{System.unique_integer([:positive])}"
    project_id = context.scope.active_project.id

    {:ok, _persona} =
      PersonasRepository.create_persona(context.scope, %{
        slug: slug,
        name: "Test Persona",
        kind: "human",
        project_id: project_id
      })

    base = Path.join(".code_my_spec/personas", slug)

    summary = """
    # Test Persona — Summary

    ## Role
    Test role.

    ## Goals
    - Test goal.

    ## Pain Points
    - Test pain.

    ## Context
    Test context.

    ## Decision Drivers
    - Test driver.

    ## Evidence
    - Test evidence.
    """

    :ok = CodeMySpec.Environments.write_file(context.environment, Path.join(base, "summary.md"), summary)
    :ok = CodeMySpec.Environments.write_file(context.environment, Path.join(base, "sources.md"), sources_content)
    :ok
  end
end
