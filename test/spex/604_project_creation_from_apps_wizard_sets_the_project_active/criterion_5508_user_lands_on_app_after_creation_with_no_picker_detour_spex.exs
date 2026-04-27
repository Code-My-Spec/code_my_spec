defmodule CodeMySpecSpex.Story604.Criterion5508Spex do
  @moduledoc """
  Story 604 — Project creation from onboarding sets the project active
  and redirects to the app
  Criterion 5508 — Rule: After successful creation the user lands on
  /app — no picker, no further forms.

  Observed via the public surface — assert the LiveView's redirect
  target after submit is `/app` (or starts with `/app/` and is not a
  picker), and that following the redirect lands cleanly without a
  further picker redirect.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "User lands on /app after creation with no picker detour" do
    scenario "User lands on /app after creation with no picker detour" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit a valid project name", context do
        context.view
        |> form("#project_form", project: %{name: "My First Project"})
        |> render_submit()

        target =
          case assert_redirect(context.view) do
            {path, _flash} -> path
            path when is_binary(path) -> path
          end

        {:ok, Map.merge(context, %{conn: recycle(context.conn), redirect_target: target})}
      end

      then_ "the redirect target is the canonical app entry, not a picker", context do
        target = context.redirect_target

        assert target == "/app" or String.starts_with?(target, "/app/"),
               "expected redirect to land within /app, got: #{target}"

        refute target =~ ~r"/picker",
               "expected redirect target to NOT be a picker URL, got: #{target}"

        {:ok, context}
      end

      then_ "following the redirect does not bounce through any picker", context do
        conn = get(context.conn, context.redirect_target)

        case conn.status do
          200 ->
            {:ok, context}

          302 ->
            next = redirected_to(conn)

            refute next =~ ~r"/accounts/picker",
                   "expected no account-picker bounce after onboarding submit, " <>
                     "got: #{next}"

            refute next =~ ~r"/projects/picker",
                   "expected no project-picker bounce after onboarding submit, " <>
                     "got: #{next}"

            {:ok, context}

          status ->
            flunk("unexpected status #{status} after following redirect to #{context.redirect_target}")
        end
      end
    end
  end
end
