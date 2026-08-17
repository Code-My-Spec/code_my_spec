defmodule CodeMySpecSpex.Story990.Criterion8216Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8216 — An existing customer gets a new project, not a replaced one.

  Rule: signing in with an account that already exists adds a project rather
  than replacing anything.

  Guided intake is written for someone with no account, but nothing stops an
  existing customer walking through it — and for them the gate is a sign-in,
  not a sign-up. Destroying what they already had would be the worst possible
  outcome of a flow whose whole promise is that nothing is lost.

  Surface: `/build` through the gate as an already-signed-in user, then
  `/app`, where both the old project and the new one must appear.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)
    :ok
  end

  spex "An existing account gains a project rather than losing one" do
    scenario "An existing customer gets a new project, not a replaced one" do
      given_ "a signed-in customer who already has a project", context do
        {:ok, _view, html} = live(context.conn, "/app")

        assert html =~ context.project.name,
               "expected the customer's existing project before migrating, got: #{html}"

        {:ok, Map.put(context, :existing_project_name, context.project.name)}
      end

      when_ "they go through guided intake and out the far side", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
        |> render_submit()

        view
        |> answer_shaping_questions()

        # Follow where the app actually sends them, rather than navigating to
        # the destination ourselves. Asserting the destination works says
        # nothing about whether the visitor is ever sent there — and they
        # were not: an authenticated visitor was bounced off /users/register
        # onto the marketing site.
        assert {:error, {:live_redirect, %{to: gate}}} =
                 view
                 |> form("form[phx-submit=confirm_names]", %{
                   plan: %{account_name: "Acme", project_name: "Widget Tracker"}
                 })
                 |> render_submit()

        assert gate == "/build/workspace",
               "expected a signed-in visitor to be sent to their workspace, got #{gate}"

        {:ok, _workspace_view, _html} = live(conn, gate)

        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the plan becomes an additional project", context do
        {:ok, _view, html} = live(context.conn, "/app/projects")

        assert html =~ "Widget Tracker",
               "expected the new project to exist, got: #{html}"

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the project they already had is untouched", context do
        assert context.html =~ context.existing_project_name,
               "expected the existing project to survive, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
