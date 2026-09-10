defmodule CodeMySpecSpex.Story560.Criterion5144Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5144 — When two personas are linked to the project and each has a
  different missing artifact, the stop-hook feedback lists both personas and
  names each one's specific gap.

  This proves the checker iterates over all personas rather than bailing on
  the first failure, and that the delegate detail string carries per-persona
  per-artifact specifics — the load-bearing property behind the "stop hook
  reports per-artifact specifics" rule.

  DRAFT. Depends on:
    - :persona_exists shared given.
    - :persona_research_task_started shared given.
    - A variant shared given for creating a second persona with a different
      slug — or the existing :persona_exists taking an argument (see below).

  Open question: :persona_exists currently hard-codes "founder". To place two
  distinct personas on the project either (a) add `:persona_exists` arity-2
  accepting attrs, (b) add a sibling shared given `:second_persona_exists`
  that creates "agency_pm", or (c) drive the second persona inline via the
  CreatePersona MCP tool. Option (a) is the most reusable and matches how
  `StoryHelpers.create_story/2` takes a keyword list of attrs.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "two personas, each with a different missing artifact" do
    scenario "feedback lists both personas with their specific gaps" do
      given_ :persona_exists

      given_ "a second persona 'agency_pm' exists and is linked to a story", context do
        # Inline CreatePersona + LinkPersonaToStory MCP calls rather than a
        # dedicated shared given, per open question in the moduledoc. Revisit
        # once :persona_exists takes attrs.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, create_response, _frame} =
          CreatePersona.execute(
            %{
              slug: "agency_pm",
              name: "Agency PM",
              headline: "PM at a small agency juggling multiple client products"
            },
            frame
          )

        second_persona_id = extract_persona_id(create_response)

        second_story =
          StoryHelpers.create_story(context.scope,
            title: "Second persona-linked story",
            description: "Story used to link the second persona onto the active project.",
            acceptance_criteria: ["Second persona links to the project via its own story"]
          )

        {:reply, _link_response, _frame} =
          LinkPersonaToStory.execute(
            %{persona_id: second_persona_id, story_id: second_story.id},
            frame
          )

        {:ok, Map.put(context, :second_slug, "agency_pm")}
      end

      given_ "'founder' is missing summary.md (sources.md present)", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            "# Sources\n\n- https://example.com — Source — 2026-04-23\n"
          )

        {:ok, context}
      end

      given_ "'agency_pm' is missing sources.md (summary.md present)", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.second_slug}/summary.md",
            minimal_persona_summary()
          )

        {:ok, context}
      end

      given_ :persona_research_task_started

      when_ "the agent calls evaluate_task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the feedback names both personas", context do
        body = response_text(context.response)

        # Anchor: confirm blocking feedback is real before checking specific slugs.
        assert body =~ ~r/Needs work|incomplete|missing|invalid/i,
               "expected blocking feedback, got #{inspect(context.response)}"

        assert body =~ context.persona_slug,
               "expected feedback to name the first persona"

        assert body =~ context.second_slug,
               "expected feedback to name the second persona"

        {:ok, context}
      end

      then_ "the feedback names 'founder' with summary.md as its gap", context do
        body = response_text(context.response)

        # The two gaps are the load-bearing bit. The checker must attribute
        # the right missing file to the right persona, not just list the
        # union of missing files across all personas.
        assert body =~
                 ~r/#{context.persona_slug}[\s\S]{0,200}summary\.md|summary\.md[\s\S]{0,200}#{context.persona_slug}/,
               "expected feedback to attribute summary.md as the gap for '#{context.persona_slug}'"

        {:ok, context}
      end

      then_ "the feedback names 'agency_pm' with sources.md as its gap", context do
        body = response_text(context.response)

        assert body =~
                 ~r/#{context.second_slug}[\s\S]{0,200}sources\.md|sources\.md[\s\S]{0,200}#{context.second_slug}/,
               "expected feedback to attribute sources.md as the gap for '#{context.second_slug}'"

        {:ok, context}
      end
    end
  end

  defp extract_persona_id(response),
    do: extract_persona_id_from(Regex.run(~r/\bid: `([^`]+)`/, response_text(response)), response)

  defp extract_persona_id_from([_, id], _response), do: id

  defp extract_persona_id_from(_, response),
    do: raise("Could not extract persona id from response: #{inspect(response)}")

  defp minimal_persona_summary do
    """
    # Agency PM

    ## Role
    Product manager at a small agency juggling three client products.

    ## Goals
    Keep each client's backlog moving without context loss.

    ## Pain Points
    Cognitive-load switching between clients several times a day.

    ## Context
    3–5 active client engagements, async-heavy communication.

    ## Decision Drivers
    Workflow tooling that scales to many small projects.

    ## Evidence
    Internal notes; customer interviews pending.
    """
  end
end
