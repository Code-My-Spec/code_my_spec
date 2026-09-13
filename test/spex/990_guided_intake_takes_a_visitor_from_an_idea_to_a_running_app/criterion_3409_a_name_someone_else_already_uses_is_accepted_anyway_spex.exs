defmodule CodeMySpecSpex.Story990.Criterion3409Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 3409 — A name someone else already uses is accepted anyway.

  (Written under this story's earlier numbering as criterion 8213; renamed
  to track the criterion after a Three Amigos renumbering. Same scenario,
  same file history.)

  Rule: the names the visitor confirmed are the names that get created.

  The failure side of the same rule, and it fails by *not* failing. Account
  names carry no uniqueness — only the derived slug does, and it suffixes
  itself. So "someone already took that" is a sentence this flow should never
  produce: it is friction invented by an implementation detail, at the exact
  moment the visitor has the least patience for it.

  Surface: `/build` through the gate, then `/app`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  @taken "Acme"

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)
    :ok
  end

  spex "A name already in use is still the name the visitor gets" do
    scenario "A name someone else already uses is accepted anyway" do
      given_ "the visitor's own account already carries the name", context do
        # The signed-in visitor's account is renamed to the contested name, so
        # the account the plan creates has to collide with a real one.
        {:ok, view, _html} = live(context.conn, "/app/accounts/#{context.account.id}/manage")

        view
        |> form("form", %{account: %{name: @taken}})
        |> render_submit()

        {:ok, context}
      end

      given_ "a visitor who has reached a plan", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
        |> render_submit()

        view
        |> answer_shaping_questions()

        {:ok, Map.merge(context, %{conn: conn, view: view})}
      end

      when_ "they confirm the name that is already in use", context do
        result =
          context.view
          |> form("form[phx-submit=confirm_names]", %{
            plan: %{account_name: @taken, project_name: "Widget Tracker"}
          })
          |> render_submit()

        {:ok, Map.put(context, :result, result)}
      end

      # Moving on to the gate is the proof: a refusal would re-render the form
      # with the name still to fix, not send them onward.
      then_ "they are never asked to pick a different name", context do
        # Onward to the gate, whichever gate applies to them — a refusal would
        # re-render the form with the name still to fix instead of moving on.
        assert {:error, {:live_redirect, %{to: gate}}} = context.result
        assert gate in ["/build/workspace", "/users/register"]

        {:ok, context}
      end

      then_ "the project is created under that name anyway", context do
        {:ok, _workspace_view, _html} = live(context.conn, "/build/workspace")
        {:ok, _view, html} = live(context.conn, "/app")

        assert html =~ "Widget Tracker",
               "expected the project to be created despite the contested account name"

        {:ok, context}
      end
    end
  end
end
