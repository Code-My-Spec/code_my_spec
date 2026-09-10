defmodule CodeMySpecSpex.Story987.Criterion8186Spex do
  @moduledoc """
  Story 987 — Harness-to-Server Projection
  Criterion 8186 — A written spex file satisfies bdd_specs_exist.

  Covers Rule "Writing the artifact a requirement gates on satisfies that
  requirement, without any further action by the agent."

  This is the case drill 12 failed on. The agent wrote 32 spex files across 9
  stories, all 32 synced, and not one was linked to a story — so
  `bdd_specs_exist` failed for every story and the 69 `implementation_file`
  requirements behind it were unreachable. The agent read the frozen graph as a
  dead file watcher and spent the rest of the run there.

  The requirement is read through `show_requirement`, the MCP tool an agent
  actually calls, rather than out of the database — a satisfied row that no
  agent-visible surface reports is not a satisfied requirement.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "An agent's spec file satisfies the requirement that asked for it" do
    scenario "writing a spex file under a story's directory satisfies bdd_specs_exist" do
      given_ "a story requires BDD specs and none exist", context do
        # Released, because an unreleased story produces no requirements at all
        # — `bdd_specs_exist` would not merely be unsatisfied, it would not
        # exist, and the scenario would pass or fail for the wrong reason.
        story =
          StoryHelpers.create_story(context.scope,
            title: "Capture a task",
            description: "A story for spex testing"
          )

        refute Fixtures.requirement_satisfied?(
                 context.scope,
                 "bdd_specs_exist",
                 :story,
                 story.id
               ),
               "the requirement must start unsatisfied or the scenario proves nothing"

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the agent writes a spex file under that story's directory and the harness delivers its manifest",
            context do
        # The durable `number`, not the primary key. Spex directories are
        # named `<number>_<slug>` and ownership resolves through
        # `story_ids_by_number`, so a path built from `id` links to nothing
        # and the requirement stays unsatisfied — which is the very symptom
        # this scenario exists to catch, arriving for the wrong reason.
        path =
          "test/spex/#{context.story.number}_capture_a_task/criterion_1_a_task_is_captured_spex.exs"

        :ok =
          Environments.write_file(
            context.environment,
            path,
            "defmodule Sample do\n  use CodeMySpecSpex.Case\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        {:ok, Map.put(context, :spex_path, path)}
      end

      then_ "bdd_specs_exist is satisfied for that story", context do
        assert Fixtures.requirement_satisfied?(
                 context.scope,
                 "bdd_specs_exist",
                 :story,
                 context.story.id
               ),
               """
               The spec is on disk and synced, but the requirement that asked for
               it is still open. That is indistinguishable, from the agent's side,
               from the file never having been written — which is why it reads as
               a broken watcher and costs a whole session.
               """

        {:ok, context}
      end
    end
  end
end
