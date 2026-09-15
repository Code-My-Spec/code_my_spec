defmodule CodeMySpecSpex.Story1063.Criterion3348Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3348 — A spex file appearing moves the graph.

  Rule: the filesystem is untrusted input, and its effect on the graph is
  decided by a fingerprint.

  The third file kind, and the one that satisfies a story-level requirement
  rather than a component-level one. `bdd_specs_exist` is answered by a file
  appearing under the story's directory, so this is the case where a file's
  effect lands on a different entity from the component ones above.

  That difference is the point of enumerating the kinds separately: "files are
  hashed" is a statement about discovery, and each kind still has to reach the
  requirement it bears on.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.ProjectBuilder

  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A spex file written into the checkout moves the graph" do
    scenario "a spex for a story's criterion appears" do
      given_ "a released story with no spex file yet", context do
        # A real story, because a spex file's directory names a story by its
        # durable `number` and the scanner resolves that to an id. A hardcoded
        # number belongs to no story here, so the file would be owned by
        # nothing and `bdd_specs_exist` could never move — which is what this
        # criterion is about.
        story = create_story(context.scope, title: "Has a spex", description: "eventually")

        before = read_settled_graph(context)

        assert satisfaction_of(before, "bdd_specs_exist", :story, story.id) == false,
               """
               The premise did not hold: this story already has BDD specs, so
               one appearing has nowhere to show up.

               bdd_specs_exist: #{inspect(satisfaction_of(before, "bdd_specs_exist", :story, story.id))}
               """

        {:ok, context |> Map.put(:new_story, story) |> Map.put(:before, before)}
      end

      when_ "a spex file appears under a story's directory and the engineer syncs",
            context do
        ProjectBuilder.new(context.environment, app: "my_app")
        |> ProjectBuilder.spex(context.new_story.number, 3348)
        |> ProjectBuilder.write!()

        sync(context)

        {:ok, context}
      end

      then_ "the graph says that story has BDD specs", context do
        after_sync = read_graph(context)

        assert satisfaction_of(after_sync, "bdd_specs_exist", :story, context.new_story.id) ==
                 true,
               """
               A spex file appeared under the story's directory and the graph
               still says the story has no BDD specs.

               `bdd_specs_exist` is answered by a file appearing under the
               story's directory, so a spex file's effect lands on a story
               rather than on a component. Discovering the file is not enough
               on its own — the hash has to reach the requirement it bears on.

               The claim is the verdict, not a clock: a pass that ran and
               applied nothing moves `computed_at` exactly as far as one that
               worked, and `checked_at` is second-resolution besides.

               bdd_specs_exist before: #{inspect(satisfaction_of(context.before, "bdd_specs_exist", :story, context.new_story.id))}
               bdd_specs_exist after:  #{inspect(satisfaction_of(after_sync, "bdd_specs_exist", :story, context.new_story.id))}
               """

        {:ok, context}
      end
    end
  end

  defp sync(context) do
    {:ok, sync_live, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/files")

    sync_live |> element("button[phx-click='sync']") |> render_click()
  end
end
