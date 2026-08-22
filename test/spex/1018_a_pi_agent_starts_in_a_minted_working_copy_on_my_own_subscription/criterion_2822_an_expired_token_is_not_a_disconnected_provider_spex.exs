defmodule CodeMySpecSpex.Story1018.Criterion2822Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2822 — An expired token is not a disconnected provider.

  Rule: An agent with no usable credential refuses to start and names the
  provider that needs connecting.

  Two states that look alike and want opposite answers. An expired *access*
  token is routine — the grant refreshes and nothing is wrong — and asking a
  human to reconnect over it is asking them to fix something that is not broken.
  A credential that can no longer be refreshed is broken, and only a human can
  fix it.

  Two scenarios rather than one, because the criterion's own "but given" is a
  different world and not a later step in the same one. Written as one, the
  first half refreshes the credential and leaves it fresh, so the second half
  finds nothing to fail on and passes for the wrong reason — which is what it
  did before it was split.

  ## Load-bearing for a failure the story records but does not solve

  OpenAI rotates the refresh token on every refresh — `readTokenResponse/2` in
  Pi's `openai-codex.js` requires `refresh_token` in the refresh response and
  stores it. Copies seeded from one credential can therefore refresh out of
  order, and a public client using rotation is the case the OAuth 2.0 Security
  BCP tells providers to treat as replay and revoke the whole grant over. When
  that happens the symptom is exactly the second scenario: a credential that
  will not refresh, arriving long after the event that caused it. Saying
  "reconnect" rather than "never connected" is the difference between a legible
  failure and a mystery.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Expired and unrefreshable are different answers" do
    scenario "An expired access token is refreshed rather than reported" do
      given_ "a connected provider whose access token has expired but whose refresh works",
             context do
        {:ok, _integration} =
          Fixtures.connect_provider(context.scope, :openai,
            expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
          )

        # Stubbed, and it should be a cassette. The house convention for outbound
        # OAuth is a recorded shape replayed through ReqCassette, and there is a
        # recording test waiting for one — `:record_openai_refresh_shape` in
        # `integrations_test.exs`. It cannot run yet: `~/.pi/agent/auth.json`
        # holds only `anthropic`, so there is no ChatGPT grant to record from,
        # and hand-writing the JSON would be manufacturing a recording rather
        # than capturing one. Swap this for `with_cassette` once the grant
        # exists.
        #
        # What it must not be is live. Before `config/test.exs` pinned Assent's
        # adapter, this criterion reached auth.openai.com from the suite and came
        # back with a real 401.
        Req.Test.stub(Assent, fn conn ->
          Req.Test.json(conn, %{
            "access_token" => "spex-refreshed-access",
            "refresh_token" => "spex-rotated-refresh",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        end)

        {:ok, context}
      end

      when_ "an engineer starts a Pi agent on it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "openai-codex"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the agent starts and nobody is asked to reconnect anything", context do
        refute context.response.isError,
               "an expired access token stopped an agent starting. Refreshing it is " <>
                 "the grant's ordinary lifecycle, so this asks a human to fix " <>
                 "something that is not broken. Got: #{response_text(context.response)}"

        {:ok, context}
      end
    end

    scenario "A credential that cannot be refreshed says reconnect" do
      given_ "a connected provider whose refresh the provider now refuses", context do
        {:ok, _integration} =
          Fixtures.connect_provider(context.scope, :openai,
            expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
          )

        # `invalid_grant` is what a revoked or superseded refresh token gets,
        # and is the shape replay revocation would arrive in.
        Req.Test.stub(Assent, fn conn ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"error" => "invalid_grant"})
        end)

        {:ok, context}
      end

      when_ "an engineer starts a Pi agent on it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "openai-codex"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "no agent is started", context do
        assert context.response.isError,
               "an agent started on a credential the provider refuses to refresh. " <>
                 "It will fail on its first model call instead. " <>
                 "Got: #{response_text(context.response)}"

        {:ok, context}
      end

      then_ "and it is reported as needing reconnecting, not as never connected",
            context do
        text = response_text(context.response)

        assert text =~ ~r/reconnect|sign in again|re-?authoriz/i,
               "a revoked credential was reported as though it had never been " <>
                 "connected. Those want opposite responses, and this is the shape " <>
                 "refresh-token replay revocation arrives in — long after the event, " <>
                 "against a provider the engineer knows they connected. Telling them " <>
                 "it was never connected sends them to set up something that already " <>
                 "exists. Got: #{text}"

        {:ok, context}
      end
    end
  end
end
