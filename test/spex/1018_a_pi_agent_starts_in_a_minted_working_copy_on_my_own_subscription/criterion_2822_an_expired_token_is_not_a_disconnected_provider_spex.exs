defmodule CodeMySpecSpex.Story1018.Criterion2822Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2822 — An expired token is not a disconnected provider.

  Rule: An agent with no usable credential refuses to start and names the provider
  that needs connecting.

  Two states that look alike and want opposite responses. An expired *access*
  token is routine — Pi refreshes it itself, inside a locked read-modify-write —
  and asking a human to reconnect over it would be asking them to fix something
  that is not broken. A credential that can no longer be refreshed is broken, and
  only a human can fix it.

  This criterion is load-bearing for a failure mode the story records but does not
  solve. OpenAI rotates the refresh token on every refresh — confirmed from
  `readTokenResponse/2` in Pi's `openai-codex.js`, which requires `refresh_token`
  in the refresh response and stores it. Copies seeded from one credential can
  therefore refresh out of order, and if the provider treats a superseded token as
  replay, the grant dies for everyone at once. When that happens the symptom is
  exactly this: a credential that will not refresh, arriving long after the event
  that caused it. Saying "reconnect" rather than "never connected" is the
  difference between a legible failure and a mystery.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Expired and unrefreshable are different answers" do
    scenario "An expired token is not a disconnected provider" do
      given_ "a connected provider whose access token has expired but whose refresh works",
             context do
        {:ok, _integration} =
          Fixtures.connect_provider(context.scope, :openai,
            expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
          )

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
                 "Pi's own job and it can still do it, so this asks a human to fix " <>
                 "something that is not broken. Got: #{response_text(context.response)}"

        {:ok, context}
      end

      then_ "a credential that cannot be refreshed says reconnect, not never-connected",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(
            %{"engine" => "pi", "provider" => "openai-codex", "refresh" => "revoked"},
            frame
          )

        assert response.isError
        text = response_text(response)

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
