defmodule CodeMySpecSpex.Story1063.Criterion3238Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3238 — Files changed out of band are caught by hashing.

  Rule: the filesystem is untrusted input, and its effect on the graph is
  decided by a fingerprint.

  The boundary of the trusted-event design. Every other input to the graph is
  ours — we write it, so it can say so. Files are not: an agent writes them, a
  git checkout replaces them, an editor saves one. There is no write of ours to
  publish from, so the only honest answer is to hash what is there and compare.

  This is why the fingerprint survives rather than being deleted outright. It
  stops being a workaround for not having events and becomes the right tool for
  the one input that genuinely cannot have them.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @impl_path "lib/out_of_band.ex"

  spex "A file written with no event behind it still reaches the graph" do
    scenario "a file appears in the working copy" do
      given_ "a project whose graph has been served", context do
        _cold = read_graph(context)
        {:ok, Map.put(context, :before, read_graph(context))}
      end

      when_ "a file appears in the working copy and the engineer syncs", context do
        # No domain event: this is a write into the checkout, the way an agent
        # or a git operation makes one. Nothing published; the scan is what
        # discovers it.
        :ok =
          Environments.write_file(context.environment, @impl_path, """
          defmodule OutOfBand do
            @moduledoc "Written with nothing announcing it."
          end
          """)

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      then_ "the graph no longer answers from the computation made before it", context do
        after_sync = read_graph(context)

        refute after_sync["computed_at"] == context.before["computed_at"],
               """
               A file appeared in the checkout and the graph went on answering
               from the computation it made before.

               Nothing published this write — it is exactly the case the
               fingerprint exists for. If a files digest does not catch it, the
               graph has no other way to learn the file is there.

               before: #{inspect(context.before["computed_at"])}
               after:  #{inspect(after_sync["computed_at"])}
               """

        {:ok, context}
      end
    end
  end

end
