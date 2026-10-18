defmodule CodeMySpecSpex.Story1060.Criterion2073Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 2073 — Every tap-out from a coding, QA or product agent reaches
  the main agent first; the user sees it only when the main agent escalates
  it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A fresh tap-out reaches the main agent, not the user", criterion: 2073 do
    scenario "a coding agent taps out while the main agent is running" do
      given_ "a running main agent and a coding agent", context do
        reply = join_working_copy(context, "/tmp/spex-2073", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-2073")
        coder = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2073")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: coder.id}}

        {:ok, Map.merge(context, %{scope: scope, asking_frame: asking})}
      end

      when_ "the coding agent taps out", context do
        tapped =
          ToolLibrary.run(
            "tap_out",
            %{reason: "this task's work should not exist"},
            Map.put(
              context.asking_frame.assigns,
              :scope,
              context.asking_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tapped), inspect(tapped)
        [_, permission_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(tapped))
        {:ok, Map.put(context, :permission_id, permission_id)}
      end

      then_ "it reaches the main agent's own waiting work", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListNotifications.execute(%{}, frame)

        assert response_text(listing) =~ context.permission_id,
               """
               A fresh tap-out never showed up in the main agent's own waiting work.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end

      then_ "and it does not reach the user yet", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        refute has_element?(
                 view,
                 "[data-test='notification'][data-id='#{context.permission_id}']"
               ),
               """
               A tap-out reached the user before the main agent ever had a chance
               to look at it.

               #{render(view)}
               """

        {:ok, context}
      end
    end
  end

  spex "The user sees a tap-out once the main agent escalates it", criterion: 2073 do
    scenario "the main agent escalates a coding agent's tap-out" do
      given_ "a coding agent's tap-out, raised while the main agent is running", context do
        reply = join_working_copy(context, "/tmp/spex-2073b", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-2073b")
        coder = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2073b")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: coder.id}}

        tapped =
          ToolLibrary.run(
            "tap_out",
            %{reason: "building this would change what the product does"},
            Map.put(asking.assigns, :scope, asking.assigns[:current_scope])
          )

        assert match?({:ok, _}, tapped), inspect(tapped)
        [_, permission_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(tapped))

        {:ok, Map.merge(context, %{scope: scope, permission_id: permission_id})}
      end

      when_ "the main agent escalates it to the user", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, escalated, _frame} =
          EscalateQuestion.execute(
            %{
              question_id: context.permission_id,
              reason: "only the user can say whether this feature should be built at all"
            },
            frame
          )

        refute escalated.isError, inspect(escalated)
        {:ok, context}
      end

      then_ "it now reaches the user", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(
                 view,
                 "[data-test='notification'][data-id='#{context.permission_id}']"
               ),
               """
               A tap-out the main agent escalated never reached the user.

               #{render(view)}
               """

        {:ok, context}
      end
    end
  end
end
