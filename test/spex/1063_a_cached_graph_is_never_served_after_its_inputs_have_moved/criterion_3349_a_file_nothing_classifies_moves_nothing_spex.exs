defmodule CodeMySpecSpex.Story1063.Criterion3349Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3349 — A file nothing classifies moves nothing.

  Rule: the filesystem is untrusted input, and its effect on the graph is
  decided by a fingerprint.

  The limit on the previous criterion. Files are hashed because nothing
  announces them, but the question the hash answers is "did anything the graph
  reads move", not "did any byte on disk move".

  An unclassified file syncs to nothing — `Scanner.classify/1` returns nil and
  the scan pipeline drops it before it reaches a record. So a graph that
  recomputed for one would recompute for every editor swapfile, build artifact
  and stray note in the tree, which is the thrash the heartbeat rules exist to
  avoid arriving through a different door.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A file the scanner ignores leaves the graph alone" do
    scenario "an unclassified file is written and synced" do
      given_ "a project whose graph has been served", context do
        _cold = read_graph(context)
        {:ok, Map.put(context, :before, read_graph(context))}
      end

      when_ "a file is written at a path the scanner does not classify", context do
        :ok =
          Environments.write_file(
            context.environment,
            "notes/scratch.txt",
            "not a thing the scanner classifies"
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      then_ "the graph answers from the same computation", context do
        after_sync = read_graph(context)

        assert after_sync["computed_at"] == context.before["computed_at"],
               """
               The graph recomputed for a file nothing classifies.

               An unclassified file is dropped before it becomes a record, so
               there is nothing for the graph to read and no reason for its
               answer to change. If it moves here, every stray artifact in a
               tree costs a recompute.

               before: #{inspect(context.before["computed_at"])}
               after:  #{inspect(after_sync["computed_at"])}
               """

        {:ok, context}
      end
    end
  end

end
