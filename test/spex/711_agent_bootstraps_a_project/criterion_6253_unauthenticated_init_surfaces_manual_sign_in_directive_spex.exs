defmodule CodeMySpecSpex.Story711.Criterion6253Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6253 — Unauthenticated init surfaces manual sign-in directive.

  When no `ClientUser` row exists with an OAuth token,
  `Init.Auth.command/2` returns a prompt that:
    1. Tells the user to sign in to CodeMySpec manually.
    2. States the agent cannot complete this step automatically.

  Surface: `AgentTasks.Init.Auth.command/2`. Default test state has no
  client_user row, so `OAuthClient.authenticated?/0` returns false.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init.Auth gates init on OAuthClient.authenticated?; failure emits manual sign-in guidance" do
    scenario "Unauthenticated init surfaces manual sign-in directive" do
      given_ "the local OAuth client reports authenticated? = false (no client_user seeded)",
             context do
        {:ok, context}
      end

      when_ "the agent calls Init.Auth.command on the scope", context do
        {:ok, prompt} = Fixtures.init_auth_command(context.scope, %{})
        {:ok, Map.put(context, :prompt, prompt)}
      end

      then_ "the prompt tells the user to sign in to CodeMySpec manually",
            context do
        assert context.prompt =~ ~r/sign in/i,
               "expected prompt to mention sign in, got:\n#{context.prompt}"

        assert context.prompt =~ ~r/CodeMySpec/,
               "expected prompt to mention CodeMySpec, got:\n#{context.prompt}"

        {:ok, context}
      end

      and_ "the prompt states the agent cannot complete this step automatically",
           context do
        assert context.prompt =~ ~r/cannot complete it automatically|requires user interaction/i,
               "expected prompt to say the agent can't do this automatically, got:\n#{context.prompt}"

        {:ok, context}
      end
    end
  end
end
