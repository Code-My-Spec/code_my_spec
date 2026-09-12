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

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A spex file written into the checkout moves the graph" do
    scenario "a spex for a story's criterion appears" do
      given_ "a project whose graph has been served", context do
        _cold = read_graph(context)
        {:ok, Map.put(context, :before, read_graph(context))}
      end

      when_ "a spex file appears under a story's directory and the engineer syncs",
            context do
        ProjectBuilder.new(context.environment, app: "my_app")
        |> ProjectBuilder.spex(1063, 3348)
        |> ProjectBuilder.write!()

        sync(context)

        {:ok, context}
      end

      then_ "the graph no longer answers from the computation made before it", context do
        after_sync = read_graph(context)

        refute after_sync["computed_at"] == context.before["computed_at"],
               """
               A spex file appeared and the graph went on answering from the
               computation it made before.

               `bdd_specs_exist` is answered by a file appearing under the
               story's directory, so a spex file's effect lands on a story
               rather than on a component. Discovering the file is not enough
               on its own — the hash has to reach the requirement it bears on.

               before: #{inspect(context.before["computed_at"])}
               after:  #{inspect(after_sync["computed_at"])}
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
