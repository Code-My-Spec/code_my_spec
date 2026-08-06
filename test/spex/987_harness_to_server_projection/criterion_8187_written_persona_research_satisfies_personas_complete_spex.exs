defmodule CodeMySpecSpex.Story987.Criterion8187Spex do
  @moduledoc """
  Story 987 — Harness-to-Server Projection
  Criterion 8187 — Written persona research satisfies personas_complete.

  Covers Rule "Writing the artifact a requirement gates on satisfies that
  requirement, without any further action by the agent."

  `PersonasChecker` used to read both files through `scope.environment` and
  answered "Environment is not available" whenever there was none — which on the
  light harness is always. An agent wrote the research, watched it sync, and was
  told on every re-evaluation that it could not be verified.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "An agent's persona research satisfies the requirement that asked for it" do
    scenario "writing summary.md and sources.md satisfies personas_complete" do
      given_ "a project has a persona with no research on disk", context do
        {:ok, persona} =
          Fixtures.create_persona(context.scope, %{
            name: "Dana Reyes",
            slug: "dana-reyes",
            status: :proto
          })

        refute Fixtures.requirement_satisfied?(
                 context.scope,
                 "personas_complete",
                 :project,
                 context.project.id
               )

        {:ok, Map.put(context, :persona, persona)}
      end

      when_ "the agent writes the persona's research and the harness delivers its manifest",
            context do
        slug = context.persona.slug

        :ok =
          Environments.write_file(
            context.environment,
            Fixtures.persona_summary_path(slug),
            persona_summary()
          )

        :ok =
          Environments.write_file(
            context.environment,
            Fixtures.persona_sources_path(slug),
            "- https://example.com/study — A study — 2026-01-15\n"
          )

        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "personas_complete is satisfied", context do
        assert Fixtures.requirement_satisfied?(
                 context.scope,
                 "personas_complete",
                 :project,
                 context.project.id
               ),
               """
               The research is on disk and synced. A checker that still reports it
               missing is telling the agent to redo work it has already done.
               """

        {:ok, context}
      end
    end
  end

  # Every section the `persona_summary` document type requires. A fixture that
  # omits one does not test the projection — it tests the validator, and fails
  # for a reason that has nothing to do with this story.
  defp persona_summary do
    """
    # Dana Reyes

    ## Role

    Keeps a list of things she owes people.

    ## Goals

    Capture a task in one gesture, and trust the list on the first look.

    ## Pain Points

    Loses things in the gap between apps; re-reads the whole list to find one item.

    ## Context

    Works from a laptop and a phone, often mid-conversation.

    ## Decision Drivers

    Speed of capture over features; the list must be useful without the product.

    ## Evidence

    Desk research; every load-bearing claim carries at least three independent
    sources, and the strongest disconfirming one is left standing.
    """
  end
end
