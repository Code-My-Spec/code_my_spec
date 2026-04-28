defmodule CodeMySpecSpex.Story607.Criterion5520Spex do
  @moduledoc """
  Story 607 — New user reaches a working app state without seeing the
  account picker.
  Criterion 5520 — Rule: A pre-existing user_return_to pointing at the
  picker is overwritten with /app on magic-link confirm.

  The session controller forces user_return_to=/app before calling
  log_in_user, so even an attacker- or stale-set user_return_to cannot
  divert the post-auth redirect into the picker.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Stale user_return_to is overwritten with /app on magic-link confirm" do
    scenario "Pre-existing user_return_to=/app/accounts/picker is overwritten with /app" do
      given_ :registered_user_with_magic_link

      when_ "the user clicks the magic link with a stale user_return_to in session",
            context do
        stale_conn =
          Phoenix.ConnTest.build_conn()
          |> Phoenix.ConnTest.init_test_session(%{})
          |> Plug.Conn.put_session(:user_return_to, "/app/accounts/picker")

        result_conn = get(stale_conn, context.magic_link_url)
        {:ok, Map.put(context, :result_conn, result_conn)}
      end

      then_ "the redirect target is /app, not the picker", context do
        assert context.result_conn.status == 302,
               "expected 302 after magic-link confirm, got #{context.result_conn.status}"

        target = redirected_to(context.result_conn)

        assert target == "/app",
               "the controller must overwrite stale user_return_to with /app, got: " <>
                 inspect(target)

        refute target == "/app/accounts/picker",
               "post-auth redirect must never resolve to the picker"

        {:ok, context}
      end
    end
  end
end
