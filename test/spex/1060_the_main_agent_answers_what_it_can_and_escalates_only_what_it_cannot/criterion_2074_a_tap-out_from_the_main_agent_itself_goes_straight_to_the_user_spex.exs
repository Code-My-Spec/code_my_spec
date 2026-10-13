defmodule CodeMySpecSpex.Story1060.Criterion2074Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 2074 — A tap-out from the main agent itself goes straight to the
  user.

  2073 is a teammate's tap-out reaching main first; this is the one asker
  with nobody above it to route to, the same exception story 1052 already
  makes for an agentless question.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent's own tap-out goes straight to the user, with no other agent to route it through",
       criterion: 2074 do
    scenario "the only main agent on the project taps itself out" do
      given_ "a lone running main agent, with no other main agent on the project", context do
        reply = join_working_copy(context, "/tmp/spex-2074", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-2074")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: main.id}}

        {:ok, Map.merge(context, %{scope: scope, asking_frame: asking})}
      end

      when_ "it taps itself out", context do
        {:reply, tapped, _frame} =
          TapOut.execute(
            %{reason: "I cannot tell whether this is still the right task to run"},
            context.asking_frame
          )

        refute tapped.isError, inspect(tapped)
        [_, permission_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(tapped))
        {:ok, Map.put(context, :permission_id, permission_id)}
      end

      then_ "it reaches the user immediately, with no main agent standing between", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(
                 view,
                 "[data-test='notification'][data-id='#{context.permission_id}']"
               ),
               """
               The main agent's own tap-out never reached the user — there is no
               other main agent for it to wait on first.

               #{render(view)}
               """

        {:ok, context}
      end
    end
  end
end
