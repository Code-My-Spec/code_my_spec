defmodule CodeMySpecSpex.Story1018.Criterion2821Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2821 — Asked for a provider that was never connected.

  Rule: An agent with no usable credential refuses to start and names the provider
  that needs connecting.

  The failure this forbids is the one `agent.sh` already learned the hard way: an
  agent that starts without a working credential fails on its first model call,
  minutes later, in a log nobody is reading. That supervisor now greps its own
  output for "OAuth session expired" and bails, because retrying an unauthenticated
  agent burns twelve minutes to arrive at the same answer with the cause buried
  under supervisor noise.

  Refusing up front costs nothing and names the thing a human has to go and do.
  The second assertion is what stops the refusal being a bare error an engineer
  still has to interpret — with several providers connectable, "no credential" does
  not say which one to go and connect.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A missing credential is refused, not discovered later" do
    scenario "Asked for a provider that was never connected" do
      given_ "an account with no ChatGPT subscription connected", context do
        {:ok, context}
      end

      when_ "an engineer asks to start a Pi agent on that provider", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "openai-codex"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "no agent is started", context do
        assert context.response.isError,
               "an agent was started on a provider with no credential. It will fail " <>
                 "on its first model call instead — minutes later, in a log nobody " <>
                 "is reading. `agent.sh` greps its own output for expired-session " <>
                 "text precisely because that failure is otherwise indistinguishable " <>
                 "from a busy API, and retrying cannot fix it."

        {:ok, context}
      end

      then_ "the refusal names the provider that needs connecting", context do
        text = response_text(context.response)

        assert text =~ "openai-codex",
               "the refusal does not name the provider. With several providers " <>
                 "connectable, an unnamed one leaves the engineer to work out which " <>
                 "of them is missing before they can act. Got: #{text}"

        {:ok, context}
      end
    end
  end
end
