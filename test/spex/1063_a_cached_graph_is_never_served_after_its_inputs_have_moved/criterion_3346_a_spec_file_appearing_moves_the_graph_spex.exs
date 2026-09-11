defmodule CodeMySpecSpex.Story1063.Criterion3346Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3346 — A spec file appearing moves the graph.

  Rule: the filesystem is untrusted input, and its effect on the graph is
  decided by a fingerprint.

  The file kinds are not interchangeable. A spec file satisfies a different
  requirement from an implementation file, which satisfies a different one
  again from a spex file, so "files are hashed" is not enough on its own — the
  hash has to reach the requirement that file bears on.

  A spec is the first of the three to appear in a component's life and the one
  the rest of the chain gates on: without it there is nothing for an
  implementation to be written against.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.ProjectBuilder

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A spec file written into the checkout moves the graph" do
    scenario "a component's spec appears" do
      given_ "a project whose graph has been served", context do
        _cold = read_graph(context)
        {:ok, Map.put(context, :before, read_graph(context))}
      end

      when_ "a context's spec file appears in the checkout and the engineer syncs",
            context do
        ProjectBuilder.new(context.environment, app: "my_app")
        |> ProjectBuilder.spec_only("Accounts")
        |> ProjectBuilder.write!()

        sync(context)

        {:ok, context}
      end

      then_ "the graph no longer answers from the computation made before it", context do
        after_sync = read_graph(context)

        refute after_sync["computed_at"] == context.before["computed_at"],
               """
               A spec file appeared in the checkout and the graph went on
               answering from the computation it made before.

               Nothing announces a file, so the fingerprint is the only way the
               graph learns a spec exists — and the rest of a component's chain
               gates on it.

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
