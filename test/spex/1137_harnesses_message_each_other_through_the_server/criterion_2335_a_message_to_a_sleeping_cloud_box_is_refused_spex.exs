defmodule CodeMySpecSpex.Story1137.Criterion2335Spex do
  @moduledoc """
  Story 1137 — Harnesses message each other through the server.
  Criterion 2335 — A message to a sleeping cloud box is refused.

  Rule: dispatch resolves the target agent's own working copy and asks that
  machine's harness, through the server, to deliver — never the sender's.

  The suite's default agent transport is a fake in-process "machine", which
  every other agent spex relies on and which never touches
  `CodeMySpec.Agents.Transport.Harness` at all. Routing the coding agent to
  the real `Harness` transport (`CodeMySpecTest.AgentTransportRouter`) is
  what makes this a spec of the harness's own unreachable-box path rather
  than of the fake's.

  'cloud-1' never joins a channel in this scenario: a working copy row with
  no live harness registered is exactly what "down" looks like from the
  server's side, since `HarnessRegistry` only holds a pid for a copy whose
  harness actually connected.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.Transport.Harness
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A message to an unreachable box is refused, naming it", criterion: 2335 do
    scenario "A message to a sleeping cloud box is refused" do
      given_ "'cloud-1' is down", context do
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)

        {:ok, cloud_copy} =
          WorkingCopies.issue(context.scope, nil,
            label: "cloud-1",
            device: Fixtures.device_fixture(context.scope)
          )

        cloud_scope = %{context.scope | active_working_copy_id: cloud_copy.id}

        coder =
          Fixtures.running_agent(cloud_scope, role: "coding", working_copy: "/srv/cloud-1/app")

        :ok = Fixtures.route_agent(coder.id, Harness)

        {:ok,
         Map.merge(context, %{
           coder_id: coder.id,
           main_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
         })}
      end

      when_ "the main agent messages its coding agent", context do
        reply =
          ToolLibrary.run(
            "message_agent",
            %{agent_id: context.coder_id, message: "What's the status?"},
            Map.put(context.main_frame.assigns, :scope, context.main_frame.assigns.current_scope)
          )

        {:ok, Map.put(context, :message_reply, reply)}
      end

      then_ "the message is refused with 'cloud-1 is not connected'", context do
        assert match?({:error, _}, context.message_reply),
               "messaging an agent on a disconnected box was not refused:\n" <>
                 response_text(context.message_reply)

        assert response_text(context.message_reply) =~ "cloud-1 is not connected",
               "the refusal did not name the unreachable box by its label:\n" <>
                 response_text(context.message_reply)

        {:ok, context}
      end
    end
  end
end
