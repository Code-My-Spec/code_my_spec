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
      given_ "a project whose graph does not know this module", context do
        before = read_settled_graph(context)

        refute requirement_on(before, "implementation_file", "OutOfBand"),
               """
               The premise did not hold: the graph already carries `OutOfBand`,
               so the file appearing has nowhere to show up.
               """

        {:ok, Map.put(context, :before, before)}
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

        assert satisfaction_on(after_sync, "implementation_file", "OutOfBand") == true,
               """
               A file appeared in the checkout and the graph does not carry the
               component it defines.

               Nothing published this write — it is exactly the case the
               fingerprint exists for. If a files digest does not catch it, the
               graph has no other way to learn the file is there.

               The claim is the verdict, not a clock: `checked_at` is
               second-resolution, so a write and the recompute answering it
               read as the same instant.

               OutOfBand implementation_file: #{inspect(satisfaction_on(after_sync, "implementation_file", "OutOfBand"))}
               components in the graph: #{inspect(after_sync["nodes"] |> Enum.map(& &1["entity_name"]) |> Enum.uniq())}
               """

        {:ok, context}
      end
    end
  end
end
