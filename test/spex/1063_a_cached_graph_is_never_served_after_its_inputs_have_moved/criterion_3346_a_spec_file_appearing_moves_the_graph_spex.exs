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
      given_ "a project whose graph carries no spec_file requirement", context do
        before = read_settled_graph(context)

        refute requirement(before, "spec_file"),
               """
               The premise did not hold: this project's graph already carries a
               `spec_file` requirement, so a spec appearing has nowhere to show
               up.

               requirements present: #{inspect(requirement_names(before))}
               """

        {:ok, Map.put(context, :before, before)}
      end

      when_ "a context's spec file appears in the checkout and the engineer syncs",
            context do
        ProjectBuilder.new(context.environment, app: "my_app")
        |> ProjectBuilder.spec_only("Accounts")
        |> ProjectBuilder.write!()

        sync(context)

        {:ok, context}
      end

      then_ "the graph says that component's spec exists", context do
        after_sync = read_graph(context)

        assert any_satisfied?(after_sync, "spec_file"),
               """
               A spec file appeared in the checkout and the graph does not say
               the component has one.

               Nothing announces a file, so the fingerprint is the only way the
               graph learns a spec exists — and the rest of a component's chain
               gates on it.

               The claim is the verdict, not a clock: a pass that ran and
               applied nothing moves `computed_at` exactly as far as one that
               worked, and `checked_at` is second-resolution besides.

               spec_file nodes after the sync: #{inspect(all_named(after_sync, "spec_file"))}
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
