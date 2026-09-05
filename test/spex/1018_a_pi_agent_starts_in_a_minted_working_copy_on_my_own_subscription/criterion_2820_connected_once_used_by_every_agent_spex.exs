defmodule CodeMySpecSpex.Story1018.Criterion2820Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2820 — Connected once, used by every agent.

  Rule: A provider credential is held once as an integration and handed to agents;
  it is never entered per agent.

  Pi's `/login` is a slash command inside its TUI — there is no `pi login`
  subcommand — so a login needs a terminal and a human. That is tolerable once. It
  is not tolerable per working copy, which is what "connect it again" would mean
  for anyone minting copies at any rate at all.

  So the credential is held where the other provider credentials are held, and
  starting an agent spends it rather than asking for it. Three copies, three
  agents, one connection.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "One connection serves every agent" do
    scenario "Connected once, used by every agent" do
      given_ "an engineer who connected their ChatGPT subscription once", context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        {:ok, context}
      end

      when_ "they start agents on three minted working copies", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        responses =
          for copy <- ["copy-a", "copy-b", "copy-c"] do
            {:reply, response, _frame} =
              StartAgent.execute(
                %{"engine" => "alloy", "provider" => "openai-codex", "working_copy" => copy},
                frame
              )

            response
          end

        {:ok, Map.put(context, :responses, responses)}
      end

      then_ "every one of them is authenticated on that subscription", context do
        for response <- context.responses do
          refute response.isError,
                 "an agent failed to start on a subscription that is already " <>
                   "connected. Got: #{response_text(response)}"
        end

        {:ok, context}
      end

      then_ "none of them asked for the subscription again", context do
        for response <- context.responses do
          text = response_text(response)

          refute text =~ ~r/log ?in|connect|authoriz|authenticat/i,
                 "starting an agent asked for the subscription again. Pi's login is " <>
                   "a TUI slash command needing a terminal and a human, so a prompt " <>
                   "per working copy is a prompt nobody can answer at the rate copies " <>
                   "are minted. Got: #{text}"
        end

        {:ok, context}
      end
    end
  end
end
