defmodule CodeMySpecSpex.Story1063.Criterion3346Spex do
  @moduledoc """
  A component discovered from its specification carries an implementation
  requirement, and the code arriving with it satisfies that requirement.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.ProjectBuilder

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A component and its code appearing move the graph" do
    scenario "a component's specification and implementation appear" do
      given_ "a project whose graph carries no implementation_file requirement", context do
        before = read_settled_graph(context)

        refute requirement(before, "implementation_file"),
               """
               The premise did not hold: this project's graph already carries a
               `implementation_file` requirement, so a spec appearing has nowhere to show
               up.

               requirements present: #{inspect(requirement_names(before))}
               """

        {:ok, Map.put(context, :before, before)}
      end

      when_ "a context's spec file appears in the checkout and the engineer syncs",
            context do
        ProjectBuilder.new(context.environment, app: "my_app")
        |> ProjectBuilder.spec_only("Accounts")
        |> ProjectBuilder.impl_only("Accounts")
        |> ProjectBuilder.write!()

        sync(context)

        {:ok, context}
      end

      then_ "the graph says that component's implementation exists", context do
        after_sync = read_graph(context)

        assert any_satisfied?(after_sync, "implementation_file"),
               "expected the new component's implementation to satisfy its requirement"

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
