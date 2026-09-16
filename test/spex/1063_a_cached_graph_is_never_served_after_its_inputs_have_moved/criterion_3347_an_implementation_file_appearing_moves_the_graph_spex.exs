defmodule CodeMySpecSpex.Story1063.Criterion3347Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3347 — An implementation file appearing moves the graph.

  Rule: the filesystem is untrusted input, and its effect on the graph is
  decided by a fingerprint.

  The second of the three file kinds, and the one an agent writes most often.
  A coding agent's whole turn is implementation files appearing; if the graph
  does not learn of them, the agent is told to write code it has already
  written — which is the phantom-work failure this story exists to end, arriving
  through the file door rather than the domain-event one.

  Written against a component whose spec already exists, because an
  implementation with no spec is a different graph state again and not the one
  under test here.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.ProjectBuilder

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An implementation file written into the checkout moves the graph" do
    scenario "a component's implementation appears beside its spec" do
      given_ "a component whose spec exists, and a graph that has been served", context do
        ProjectBuilder.new(context.environment, app: "my_app")
        |> ProjectBuilder.spec_only("Accounts")
        |> ProjectBuilder.write!()

        sync(context)

        before = read_settled_graph(context)

        assert satisfaction_on(before, "implementation_file", "MyApp.Accounts") == false,
               """
               The premise did not hold: `MyApp.Accounts` is supposed to have a
               spec and no implementation yet, so one appearing has nowhere to
               show up.

               implementation_file nodes: #{inspect(all_named(before, "implementation_file"))}
               """

        {:ok, Map.put(context, :before, before)}
      end

      when_ "the implementation file appears and the engineer syncs", context do
        ProjectBuilder.new(context.environment, app: "my_app")
        |> ProjectBuilder.impl_only("Accounts")
        |> ProjectBuilder.write!()

        sync(context)

        {:ok, context}
      end

      then_ "the graph says that component has an implementation", context do
        after_sync = read_graph(context)

        assert satisfaction_on(after_sync, "implementation_file", "MyApp.Accounts") == true,
               """
               An implementation file appeared and the graph still says the
               component has none.

               A coding agent's turn is implementation files appearing. If the
               graph does not learn of them, the agent is handed back work it
               has already done.

               The claim is the verdict, not a clock: a pass that ran and
               applied nothing moves `computed_at` exactly as far as one that
               worked, and `checked_at` is second-resolution besides.

               implementation_file nodes: #{inspect(all_named(after_sync, "implementation_file"))}
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
