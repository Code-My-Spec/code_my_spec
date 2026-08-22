defmodule CodeMySpecSpex.Story1018.Criterion2825Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2825 — Two credential kinds, one way to start an agent.

  Rule: A provider credential is held once as an integration and handed to agents;
  it is never entered per agent.

  Pi's own credential store already settles the shape: `auth.json` holds exactly
  two kinds, `{type: "api_key", key, env?}` and `{type: "oauth", refresh, access,
  expires}`, keyed by provider id, and every OAuth provider shares the one shape.
  There is no per-provider token model to write.

  The two kinds are not hypothetical here. The ChatGPT subscription this story
  names is the OAuth kind; Z.AI's GLM Coding Plan — the daily driver in
  `pi_setup`'s `models.json` — is an API key. Both have to work, and the point of
  the rule is that they work through the same start, differing only in the
  provider named. Somewhere that knows one provider from another is somewhere a
  third provider needs a change.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Credential kind is not the caller's problem" do
    scenario "Two credential kinds, one way to start an agent" do
      given_ "a subscription connected by OAuth and a coding plan connected by API key",
             context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        # No refresh token, expiry far out — the shape an API key is stored in,
        # and the shape GitHub already uses.
        {:ok, _api_key} =
          Fixtures.connect_provider(context.scope, :zai,
            refresh_token: nil,
            expires_at: DateTime.add(DateTime.utc_now(), 31_536_000, :second)
          )

        {:ok, context}
      end

      when_ "an engineer starts an agent on each", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, oauth_response, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "openai-codex"}, frame)

        {:reply, api_key_response, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "zai"}, frame)

        {:ok,
         context
         |> Map.put(:oauth_response, oauth_response)
         |> Map.put(:api_key_response, api_key_response)}
      end

      then_ "both start", context do
        refute context.oauth_response.isError,
               "the OAuth-kind provider failed to start. " <>
                 "Got: #{response_text(context.oauth_response)}"

        refute context.api_key_response.isError,
               "the API-key-kind provider failed to start. Z.AI is the daily driver " <>
                 "in pi_setup's models.json, so this is the ordinary case rather " <>
                 "than the exotic one. Got: #{response_text(context.api_key_response)}"

        {:ok, context}
      end

      then_ "they differ only in the provider named", context do
        oauth = response_text(context.oauth_response)
        api_key = response_text(context.api_key_response)

        refute oauth =~ ~r/oauth|refresh token/i,
               "starting an agent reported the credential's kind back to the caller. " <>
                 "Pi resolves both kinds from one file keyed by provider id; a start " <>
                 "surface that distinguishes them is a surface a third provider has " <>
                 "to change. Got: #{oauth}"

        refute api_key =~ ~r/api[ _]?key/i,
               "same, for the API-key provider. Got: #{api_key}"

        {:ok, context}
      end
    end
  end
end
