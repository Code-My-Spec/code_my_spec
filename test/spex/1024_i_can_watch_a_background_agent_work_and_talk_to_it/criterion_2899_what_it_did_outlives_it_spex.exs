defmodule CodeMySpecSpex.Story1024.Criterion2899Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2899 — What it did outlives it.

  Rule: An agent's conversation stays readable after the agent stops.

  Watching is retrospective as often as live. The question "what did that agent
  actually do" is usually asked after it has finished, and often because
  something is wrong.

  This is worth a criterion because the model change makes losing it plausible.
  Conversations are moving from per-copy — where they outlived every agent
  simply by belonging to something more permanent — to per-agent, and the old
  ones are being deleted outright. A conversation that is cleaned up with its
  agent would be a reasonable-looking extension of that decision, and would
  throw away the record at the moment it is most wanted.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The record outlives the agent" do
    scenario "What it did outlives it" do
      given_ "an agent that did work", context do
        copy = CodeMySpec.TempFile.dir("spex_2899")
        File.mkdir_p!(copy)

        agent = Fixtures.start_agent_for(context.scope, working_copy: copy)
        start_agent(agent.id, working_copy: copy)

        Fixtures.agent_reports_step(context.scope, agent, %{
          "type" => "tool_use",
          "name" => "write",
          "input" => %{"file_path" => "lib/it_did_this.ex"}
        })

        {:ok, context |> Map.put(:agent, agent)}
      end

      when_ "it has since been stopped", context do
        {:ok, _stopped} = Fixtures.stop_agent(context.scope, context.agent)

        {:ok, context}
      end

      then_ "everything it did is still there to read", context do
        conversation = Fixtures.agent_conversation(context.scope, context.agent)

        assert conversation,
               "the conversation went with the agent. The question 'what did that " <>
                 "agent do' is usually asked after it stopped, and usually because " <>
                 "something is wrong."

        {:ok, live, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{conversation.id}"
          )

        assert html =~ "it_did_this",
               "the conversation survives but its contents do not, which is the same " <>
                 "loss with an extra step"

        {:ok, context |> Map.put(:html, html) |> Map.put(:live, live)}
      end

      then_ "and it is clear the agent is no longer running", context do
        assert context.html =~ ~r/stopped|not running|finished/i,
               "a stopped agent's conversation reads exactly like a running one's, " <>
                 "so an operator cannot tell whether they are watching work in " <>
                 "progress or a record of work that ended. Got: " <>
                 String.slice(context.html, 0, 300)

        {:ok, context}
      end
    end
  end
end
