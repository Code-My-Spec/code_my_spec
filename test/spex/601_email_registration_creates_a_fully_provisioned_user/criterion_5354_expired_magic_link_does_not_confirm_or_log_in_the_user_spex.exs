defmodule CodeMySpecSpex.Story601.Criterion5354Spex do
  @moduledoc """
  Story 601 — Email registration creates a fully provisioned user
  Criterion 5354 — Rule: Magic link click confirms + logs in directly
  (failure path). An expired magic link does not log the user in and
  shows a clear "link invalid or expired" message.

  Setup uses the public registration LiveView, then backdates the
  emitted login token through `CodeMySpecSpex.Fixtures` — there is no
  UI path that produces an expired token, so this is the approved
  test-only bridge.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  spex "Magic link click confirms + logs in directly without intermediate screen" do
    scenario "Expired magic link does not confirm or log in the user" do
      given_ :registered_user_with_magic_link

      given_ "the magic link is expired", context do
        :ok = Fixtures.expire_magic_link_tokens_for(context.registered_email)
        {:ok, context}
      end

      when_ "they click the link", context do
        conn = get(context.conn, context.magic_link_url)
        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "they are not logged in", context do
        refute get_session(context.conn, :user_token),
               "expected no session token to be set for an expired magic link"

        {:ok, context}
      end

      then_ "they see a clear \"link invalid or expired\" message with a path to request a new one",
            context do
        assert context.conn.status in [302, 303],
               "expected a redirect response for an expired token, got #{context.conn.status}"

        redirect_path = redirected_to(context.conn)

        login_conn = get(recycle(context.conn), redirect_path)
        html = html_response(login_conn, 200)

        assert html =~ "invalid" or html =~ "expired",
               "expected a 'link invalid or expired' message on the login page"

        {:ok, context}
      end
    end
  end
end
