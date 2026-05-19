defmodule CodeMySpecSpex.Story604.Criterion5507Spex do
  @moduledoc """
  Story 604 — Project creation from onboarding sets the project active
  and redirects to the app
  Criterion 5507 — Rule: Submitting the project name pre-selects the
  new project as the user's active project.

  Observed via the public surface — after submitting, the user can
  reach a `:require_active_project` route (`/app/issues`) without
  being bounced to the project picker. That gate only opens when
  scope.active_project is non-nil and points at a project the user
  can access.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Active project preference is set to the new project" do
    scenario "Active project preference is set after onboarding submit" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit a valid project name", context do
        context.view
        |> form("#project_form", project: %{name: "My First Project"})
        |> render_submit()

        _target = assert_redirect(context.view)

        {:ok, Map.put(context, :conn, recycle(context.conn))}
      end

      then_ "an active-project-gated route loads without a picker redirect", context do
        conn = get(context.conn, "/app/issues")
        assert_no_picker_redirect(conn.status, conn, context)
      end
    end
  end

  defp assert_no_picker_redirect(200, _conn, context), do: {:ok, context}

  defp assert_no_picker_redirect(302, conn, context) do
    target = redirected_to(conn)

    refute target =~ ~r"/projects/picker",
           "expected scope.active_project to be set after onboarding submit — got picker redirect to #{target}"

    {:ok, context}
  end

  defp assert_no_picker_redirect(status, _conn, _context),
    do: flunk("unexpected status #{status} reaching /app/issues")
end
