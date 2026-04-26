defmodule CodeMySpecSpex.Story601.Criterion5359Spex do
  @moduledoc """
  Story 601 — Email registration creates a fully provisioned user
  Criterion 5359 — Rule: After successful auth, the user lands on
  /app/onboarding.

  Setup uses the public registration LiveView; the magic link is
  pulled from the email captured by Swoosh's test adapter; the
  assertion observes the magic-link controller's redirect target.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import_givens CodeMySpecSpex.SharedGivens

  spex "After successful auth user lands on /app/onboarding" do
    scenario "Successful magic link authentication redirects to /app/onboarding" do
      given_ :registered_user_with_magic_link

      when_ "the authentication completes successfully", context do
        conn = get(context.conn, context.magic_link_url)
        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the response is a redirect to /app/onboarding", context do
        assert context.conn.status == 302,
               "expected a 302 redirect after magic-link authentication, " <>
                 "got status #{context.conn.status}"

        assert redirected_to(context.conn) == "/app/onboarding",
               "expected redirect to /app/onboarding"

        :ok
      end
    end
  end
end
