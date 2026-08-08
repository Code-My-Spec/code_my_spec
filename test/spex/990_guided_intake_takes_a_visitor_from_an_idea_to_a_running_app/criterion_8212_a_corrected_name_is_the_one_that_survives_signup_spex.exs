defmodule CodeMySpecSpex.Story990.Criterion8212Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8212 — A corrected name is the one that survives signup.

  Rule: the names the visitor confirmed are the names that get created.

  The plan proposes names because making the visitor invent them is friction
  at the worst possible moment. That is only safe if a correction is
  authoritative — a proposal that quietly wins over the visitor's own edit is
  worse than never proposing at all.

  Surface: `/build` through the gate, then `/app`, where the project the
  visitor now owns is named back to them.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecTest.FakeWorkspaceRunner

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces,
      runner: FakeWorkspaceRunner,
      boot_timeout: 5_000,
      poll_interval: 20
    )

    start_supervised!({FakeWorkspaceRunner, healthy?: true})
    on_exit(fn -> Application.delete_env(:code_my_spec, CodeMySpec.Workspaces) end)
    :ok
  end

  spex "The names the visitor confirmed are the names that get created" do
    scenario "A corrected name is the one that survives signup" do
      given_ "a plan proposing names the visitor did not choose", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
        |> render_submit()

        proposed =
          view
          |> form("form[phx-submit=answer]", %{
            plan: %{needs_sign_in: "true", separate_copies: "true", who_uses: "salon owners"}
          })
          |> render_submit()

        {:ok, Map.merge(context, %{conn: conn, view: view, proposed: proposed})}
      end

      when_ "the visitor corrects both names and goes through the gate", context do
        context.view
        |> form("form[phx-submit=confirm_names]", %{
          plan: %{account_name: "Acme", project_name: "Widget Tracker"}
        })
        |> render_submit()

        {:ok, _workspace_view, _html} = live(context.conn, "/build/workspace")

        {:ok, context}
      end

      then_ "the project is created under the name the visitor confirmed", context do
        {:ok, _view, html} = live(context.conn, "/app")

        assert html =~ "Widget Tracker",
               "expected the confirmed project name on the dashboard, got: #{html}"

        {:ok, context}
      end
    end
  end
end
