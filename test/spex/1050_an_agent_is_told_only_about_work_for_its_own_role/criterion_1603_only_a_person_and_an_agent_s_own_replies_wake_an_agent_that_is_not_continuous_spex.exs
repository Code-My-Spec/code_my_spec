defmodule CodeMySpecSpex.Story1050.Criterion1603Spex do
  @moduledoc """
  Story 1050 — An agent is told only about work for its own role.
  Criterion 1603 — Only a person and an agent's own replies wake an agent that
  is not continuous.

  John, 2026-10-01: an agent outside the loop is not nudged, offered work, sent
  findings or pinged by the cadence. It hears a person, and the answers to what
  it asked for itself. Everything goes through one wake decision
  (`Agents.Wake`), so this is asserted from the outside: what the agent is
  actually sent.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()
    :ok
  end

  spex "Only a person and an agent's own replies wake an agent that is not continuous",
    criterion: 1603 do
    scenario "An agent outside the loop hears a person, not the fleet" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a main agent that is not continuous, and an app that files issues", context do
        # On the main checkout: that is where "the main agent" is looked for.
        {:ok, _} =
          CodeMySpec.WorkingCopies.designate_main(
            context.scope,
            context.scope.active_working_copy_id
          )

        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        key = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

        Fixtures.set_project_deploy_key(context.scope, context.scope.active_project, key)

        {:ok,
         context
         |> Map.merge(%{agent: main, deploy_key: key})
         |> Map.put(:before, heard_count(context, main.id))}
      end

      when_ "an end user of the app files an issue through the widget", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{context.deploy_key}")
        |> post(~p"/api/widget/issues", %{
          "issue" => %{
            "title" => "the export button does nothing",
            "description" => "clicked twice"
          }
        })
        |> Phoenix.ConnTest.json_response(201)

        {:ok, context}
      end

      then_ "main is not woken by it", context do
        # The notice is sent from a task, so the transport is given a moment.
        main_id = context.agent.id
        refute_receive {:agent_message, ^main_id, _text}, 1_000

        refute_told_anything(
          context,
          context.agent.id,
          context.before,
          "a main agent outside the loop was woken by a widget issue"
        )

        {:ok, context}
      end

      when_ "a person sends it a message from its conversation", context do
        {:ok, view, _html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, context.agent))

        view
        |> form("[data-test='agent-message-form']", message: "Look at the refund path next")
        |> render_submit()

        {:ok, context}
      end

      then_ "the message reaches it", context do
        assert Enum.any?(
                 said_since(context, context.agent.id, context.before),
                 &(&1 =~ "Look at the refund path next")
               ),
               "a person's message did not reach an agent that is not continuous"

        {:ok, context}
      end
    end
  end
end
