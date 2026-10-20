defmodule CodeMySpecSpex.Story1137.Criterion2334Spex do
  @moduledoc """
  Story 1137 — Harnesses message each other through the server.
  Criterion 2334 — The main agent on Sam's laptop messages a coding agent in
  the cloud.

  Rule: dispatch resolves the target agent's own working copy and asks that
  machine's harness, through the server, to deliver — never the sender's.

  Drives the real channel for the cloud copy (`HarnessProjectChannel`), the
  surface a harness actually uses, rather than the in-process recording
  transport other message_agent spex swap in: this story is about what
  crosses the wire between two machines, so the wire has to be real for at
  least one of them. Sam's laptop gets its own working copy too, so the
  criterion's two boxes are two real rows, but it never joins a channel of
  its own — sending a message never requires one.
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.Transport.Harness
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.WorkingCopyHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    # The channel is another process; an owner-only sandbox connection is
    # invisible to it.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A message crosses from one machine to another through the server alone",
    criterion: 2334 do
    scenario "The main agent on Sam's laptop messages a coding agent in the cloud" do
      given_ "Sam's main copy is on his laptop and a coding copy is on 'cloud-1'", context do
        {:ok, laptop} =
          WorkingCopies.issue(context.scope, nil,
            label: "Sam's laptop",
            device: Fixtures.device_fixture(context.scope)
          )

        laptop_scope = %{context.scope | active_working_copy_id: laptop.id}
        main = Fixtures.running_agent(laptop_scope, role: "main", continuous: true)

        {cloud_reply, cloud_socket} =
          WorkingCopyHelpers.join_working_copy_socket(context, "/srv/cloud-1/app", "cloud-1")

        cloud_scope = %{context.scope | active_working_copy_id: cloud_reply.working_copy_id}

        coder =
          Fixtures.running_agent(cloud_scope, role: "coding", working_copy: "/srv/cloud-1/app")

        :ok = Fixtures.route_agent(coder.id, Harness)

        {:ok,
         Map.merge(context, %{
           coder_id: coder.id,
           cloud_socket: cloud_socket,
           main_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
         })}
      end

      when_ "the main agent messages the coding agent", context do
        task =
          Task.async(fn ->
            ToolLibrary.run(
              "message_agent",
              %{agent_id: context.coder_id, message: "Here's the next piece of work."},
              Map.put(
                context.main_frame.assigns,
                :scope,
                context.main_frame.assigns.current_scope
              )
            )
          end)

        assert_push "mailbox_delivery", pushed, 2_000

        assert pushed["agent_id"] == context.coder_id,
               "the dispatch that left the server did not name the coding agent on cloud-1"

        Phoenix.ChannelTest.push(context.cloud_socket, "agent_send_result", %{
          "ref" => pushed["ref"],
          "status" => "ok",
          "disposition" => "started"
        })

        {:ok, Map.put(context, :message_reply, Task.await(task, 3_000))}
      end

      then_ "the coding agent receives it", context do
        assert match?({:ok, _}, context.message_reply),
               "the message to the coding agent on cloud-1 was not delivered:\n" <>
                 response_text(context.message_reply)

        {:ok, context}
      end

      then_ "and neither box connected to the other", context do
        refute_receive %Phoenix.Socket.Message{},
                       100,
                       "a second round trip went out delivering this message — cloud-1 " <>
                         "should be the only machine ever asked anything, with no " <>
                         "coordination routed through Sam's own box"

        {:ok, context}
      end
    end
  end
end
