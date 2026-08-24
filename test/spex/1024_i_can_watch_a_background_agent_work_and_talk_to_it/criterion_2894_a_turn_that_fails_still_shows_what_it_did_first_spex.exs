defmodule CodeMySpecSpex.Story1024.Criterion2894Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2894 — A turn that fails still shows what it did first.

  Rule: An agent's work appears as it happens, not only when the turn ends.

  The failure path that matters more than its happy path, and the one the
  obvious implementation gets wrong.

  Buffering a turn and writing it when it completes passes "I watch the work
  arrive" on any turn that succeeds, and loses everything on the turns you most
  wanted to watch. Streaming exists so you can see an agent going wrong early;
  if the record of what it did evaporates the moment it fails, you get the
  worst of both — no live view of the mistake, and no history of it either.

  So a step that happened is a step that stays, whatever the turn does
  afterwards.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version CodeMySpecWeb.HarnessProjectChannel.contract_version()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "What already happened is not undone by what happens next" do
    scenario "A turn that fails still shows what it did first" do
      given_ "an agent part-way through a turn", context do
        copy = CodeMySpec.TempFile.dir("spex_2894")
        File.mkdir_p!(copy)

        agent = Fixtures.running_agent(context.scope, working_copy: copy)
        start_agent(agent.id, working_copy: copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_2894", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        report(socket, agent, %{"kind" => "tool_use", "text" => "write lib/half_done.ex"})

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:socket, socket)}
      end

      when_ "the turn then fails", context do
        report(context.socket, context.agent, %{
          "kind" => "turn_failed",
          "text" => "codex exec failed with status 1"
        })

        {:ok, context}
      end

      then_ "the steps it completed before failing are there", context do
        conversation = Fixtures.agent_conversation(context.scope, context.agent)

        {:ok, _live, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{conversation.id}"
          )

        assert html =~ "half_done",
               "the work the agent did before the turn failed is gone. That is the " <>
                 "buffered implementation: hold the turn, write it on success, lose " <>
                 "it on failure — which loses exactly the turns worth watching."

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and the failure is shown rather than the work disappearing with it",
            context do
        assert context.html =~ "failed",
               "the turn failed and the conversation does not say so, which leaves " <>
                 "an operator watching a transcript that simply stops"

        {:ok, context}
      end
    end
  end

  # One step, on the channel the machine sends it on, waited out before anything
  # is asked of the record — otherwise a green run only means the push was fast.
  defp report(socket, agent, event) do
    ref =
      Phoenix.ChannelTest.push(socket, "agent_turn_event", %{
        "agent_id" => agent.id,
        "event" => event
      })

    Phoenix.ChannelTest.assert_reply(ref, :ok)
  end
end
