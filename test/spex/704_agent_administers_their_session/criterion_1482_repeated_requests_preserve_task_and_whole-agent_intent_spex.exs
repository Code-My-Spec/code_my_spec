defmodule CodeMySpecSpex.Story704.Criterion3584Spex do
  @moduledoc """
  Pending tap-out identity includes both owner and task-versus-whole-agent intent.
  Retrying the same intent reuses its request; changing intent creates a separate
  human decision. Requests are created through the actual MCP tool.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Tap-out retries preserve owner and intent boundaries", criterion: 1482 do
    scenario "Task and whole-agent requests remain separate while each can be retried" do
      given_ "two durable agents each own an active task", context do
        caller = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        {caller, task} = Fixtures.agent_task_fixture(context.scope, caller)
        other = Fixtures.running_agent(context.scope, role: "qa", continuous: true)
        {other, other_task} = Fixtures.agent_task_fixture(context.scope, other)

        {:ok,
         Map.merge(context, %{
           caller_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: caller.id}},
           other_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: other.id}},
           task_id: task.id,
           other_task_id: other_task.id
         })}
      end

      when_ "each agent requests task tap-out and the caller also requests whole-agent tap-out",
            context do
        requests = [
          {context.caller_frame, context.task_id},
          {context.caller_frame, context.task_id},
          {context.caller_frame, nil},
          {context.caller_frame, nil},
          {context.other_frame, context.other_task_id},
          {context.other_frame, context.other_task_id}
        ]

        ids =
          Enum.map(requests, fn {frame, task_id} ->
            {:reply, response, _} = TapOut.execute(%{task_id: task_id}, frame)
            refute response.isError, response_text(response)
            [_, id] = Regex.run(~r/request_id=`([a-f0-9-]+)`/, response_text(response))
            id
          end)

        {:ok, Map.put(context, :request_ids, ids)}
      end

      then_ "only identical pending intents share an id", context do
        [task, task_retry, whole, whole_retry, other, other_retry] = context.request_ids
        assert task == task_retry
        assert whole == whole_retry
        assert other == other_retry
        assert length(Enum.uniq([task, whole, other])) == 3
        {:ok, context}
      end

      then_ "three separate human decisions retain their original task links", context do
        [task, _, whole, _, other, _] = context.request_ids
        {:ok, task_view, _} = live(context.conn, "/app/permissions/#{task}")
        {:ok, whole_view, _} = live(context.conn, "/app/permissions/#{whole}")
        {:ok, other_view, _} = live(context.conn, "/app/permissions/#{other}")
        assert has_element?(task_view, "[data-test='approve-permission']")
        assert has_element?(whole_view, "[data-test='approve-permission']")
        assert has_element?(other_view, "[data-test='approve-permission']")
        assert render(task_view) =~ context.task_id
        refute render(whole_view) =~ context.task_id
        assert render(other_view) =~ context.other_task_id
        refute render(other_view) =~ context.task_id
        {:ok, context}
      end
    end
  end
end
