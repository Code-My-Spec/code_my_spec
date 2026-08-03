defmodule CodeMySpecSpex.Story987.Criterion8192Spex do
  @moduledoc """
  Story 987 — Harness-to-Server Projection
  Criterion 8192 — A spec written for a story created after the harness joined
  is still linked.

  Covers Rule "A file belongs to the story or component the server currently
  knows about, not the one the harness cached when it joined."

  A sprite joins before its project has any stories. The harness fetched its
  read model once, on join, and `resolve_owners/2` refuses to link a file to a
  story that read model has never heard of — a rule that is right against a
  fresh cache and exactly wrong against one that can no longer change.

  Drill 12 wrote 32 spec files across 9 stories created during the session. Not
  one was linked; `bdd_specs_exist` failed for every story and the 69
  `implementation_file` requirements behind it were unreachable.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Ownership follows the server's domain, not a cache from join time" do
    scenario "a spec for a story that did not exist at join time is still linked" do
      given_ "the project had no stories when the harness first synced", context do
        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      when_ "a story is created and the agent writes a spec for it", context do
        story =
          Fixtures.story_fixture(context.scope, %{
            title: "Capture a task",
            ready_for_dev: true
          })

        :ok =
          Environments.write_file(
            context.environment,
            "test/spex/#{story.id}_capture_a_task/criterion_1_a_task_is_captured_spex.exs",
            "defmodule Sample do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)
        {:ok, Map.put(context, :story, story)}
      end

      then_ "the file is linked to that story", context do
        assert Fixtures.requirement_satisfied?(
                 context.scope,
                 "bdd_specs_exist",
                 :story,
                 context.story.id
               ),
               """
               The spec belongs to a story created after the last sync. If
               ownership is decided from a cache taken at join time, every file an
               agent writes during a session belongs to nothing, and no
               story-scoped requirement can ever be satisfied.
               """

        {:ok, context}
      end
    end
  end
end
