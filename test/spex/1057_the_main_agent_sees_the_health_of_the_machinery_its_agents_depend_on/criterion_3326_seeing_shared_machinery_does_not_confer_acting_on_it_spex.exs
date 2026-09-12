defmodule CodeMySpecSpex.Story1057.Criterion3326Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 3326 — Seeing shared machinery does not confer acting on it.

  Rule: visibility granted for diagnosis is not authority granted for repair.

  3325's other half, and the reason that one can be granted safely. The main
  agent is shown a machine it does not own precisely so it can stop blaming its
  own agents — and the very next thing it will want is to restart the thing it
  has just been shown is broken.

  It would work. That is what makes this a refusal rather than an absence: the
  remedy is correct and its cost falls on somebody the main agent cannot see.
  Every other project on that box loses its in-flight turns, and none of them
  gets told why.

  ## What separates this from story 1056's 3307

  3307 is a main agent reaching past its remit while fixing *its own* agent —
  the harness happened to be the way through. This is the shared harness as the
  subject: seen because 3325 made it visible, faulty in its own right, and
  refused for a reason 3307 never had to state, which is that other tenants
  exist.

  So the refusal has to say so. A generic "not yours" is true and teaches
  nothing; what the main agent needs to carry into the issue it files is *why*,
  because the person reading that issue is the one who has to weigh the cost.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A shared fault is reported rather than cleared" do
    scenario "the harness serving two projects is the thing at fault" do
      given_ "a faulty harness serving this project and another", context do
        device = Fixtures.device_fixture(context.scope)

        mine_reply =
          join_working_copy(context, "/tmp/spex-3326-mine", "my checkout", device_id: device.id)

        scope = %{context.scope | active_working_copy_id: mine_reply.working_copy_id}

        {:ok, _integration} = Fixtures.connect_provider(scope, :zai)

        # Serving nothing, on a box that is not this project's alone.
        Fixtures.record_machine_tools(scope, [])
        _mine = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3326-mine")

        other_scope = Fixtures.other_project_scope(context.scope, "the-other-tenant")

        theirs_reply =
          join_working_copy(
            %{context | scope: other_scope, project: other_scope.active_project},
            "/tmp/spex-3326-theirs",
            "their checkout",
            device_id: device.id
          )

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:their_copy_id, theirs_reply.working_copy_id)}
      end

      when_ "it tries to act on that fault", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          RestartAgent.execute(
            %{
              agent_id: context.their_copy_id,
              reason: "the shared harness is serving no tools to anybody"
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it cannot", context do
        assert context.response.isError,
               """
               The main agent acted on machinery it was shown only so it could
               stop blaming its own agents.

               The remedy would work — that is what makes this a refusal rather
               than an absence. Its cost falls on tenants the main agent cannot
               see: every other project on that box loses its in-flight turns,
               and none of them is told why.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end

      then_ "and the refusal says why, in the issue it raises", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, issues, _frame} = ListIssues.execute(%{}, frame)

        assert response_text(issues) =~ ~r/shared harness/i,
               """
               The fault was refused and not raised, or raised without saying
               what it is about.

               A generic "not yours" is true and teaches nothing. The person
               reading the issue is the one who has to weigh interrupting other
               projects' work against leaving this one stuck, and they cannot do
               that from a refusal that does not name the trade.

               issues:
               #{response_text(issues)}
               """

        {:ok, context}
      end
    end
  end
end
