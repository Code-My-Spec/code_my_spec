defmodule CodeMySpecSpex.Story711.Criterion6252Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6252 — OAuth-authenticated scope satisfies Init.Auth.

  When a `ClientUser` row exists with an unexpired OAuth token (the same
  predicate `OAuthClient.authenticated?/0` checks), `Init.Auth.evaluate/2`
  returns `{:ok, :valid}`.

  Surface: `AgentTasks.Init.Auth.evaluate/2`. The authenticated state is
  set up via `Fixtures.client_user_fixture/1`, which seeds the same row
  shape the real OAuth flow writes.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init.Auth gates init on OAuthClient.authenticated?; failure emits manual sign-in guidance" do
    scenario "OAuth-authenticated scope satisfies Init.Auth" do
      given_ "the local OAuth client reports authenticated? = true",
             context do
        _client_user = Fixtures.client_user_fixture(context.user)
        {:ok, context}
      end

      when_ "the agent calls Init.Auth.evaluate on the scope", context do
        {:ok, Map.put(context, :evaluate_result, Fixtures.init_auth_evaluate(context.scope, %{}))}
      end

      then_ "the result is {:ok, :valid}", context do
        assert context.evaluate_result == {:ok, :valid},
               "expected {:ok, :valid}, got: #{inspect(context.evaluate_result)}"

        {:ok, context}
      end
    end
  end
end
