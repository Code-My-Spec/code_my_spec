defmodule CodeMySpecSpex.IssuePromotionHelpers do
  @moduledoc """
  An issue's team, on the coding agent's copy of
  `PromotionHelpers.a_promotable_project/1`, carried through its turns by the
  tools its agents call (story 1091) — so a fix can be promoted through the
  queue like a story's work.

  Main creates, accepts and assigns the issue; the coder fixes it; QA passes
  it; the coder promotes it. Each step is the MCP tool the agent would call.
  """

  import ExUnit.Assertions
  import CodeMySpecSpex.TaskResponseHelpers

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.PromotionHelpers

  @doc """
  A team of a coder and a QA agent on the coding agent's copy, and main
  assigning it an accepted issue. Adds `:issue_id`, `:coder`, `:qa`, `:team`,
  `:main` and `:main_frame`.
  """
  def an_issue_assigned_to_the_team(context) do
    main_scope = %{context.scope | active_working_copy_id: context.running.working_copy_id}
    main = Fixtures.running_agent(main_scope, role: "main", working_copy: context.running_root)

    team =
      for role <- ~w(coding qa),
          do: Fixtures.running_agent(context.scope, role: role, working_copy: context.agent_root)

    main_frame = %Frame{assigns: %{current_scope: main_scope, agent_id: main.id}}

    created =
      call(main_frame, "create_issue", %{
        title: "An agent notification is lost",
        description: "Restore delivery so the waiting agent receives its notification.",
        severity: "high",
        scope: "framework"
      })

    issue_id = extract_issue_id!(created)
    call(main_frame, "accept_issue", %{issue_id: issue_id})

    call(main_frame, "assign_issue_to_working_copy", %{
      issue_id: issue_id,
      working_copy_id: context.scope.active_working_copy_id
    })

    Map.merge(context, %{
      issue_id: issue_id,
      main: main,
      main_frame: main_frame,
      team: team,
      coder: Enum.find(team, &(&1.role == :coding)),
      qa: Enum.find(team, &(&1.role == :qa))
    })
  end

  @doc "The coder takes `fix_issue`, commits `path`, and completes the task."
  def the_coder_fixes_it(context, path, content) do
    task_id = take(context, context.coder, "fix_issue")
    PromotionHelpers.commit_work(context, context.agent_root, path, content)

    # fix_issue now certifies the copy for QA the way ready_for_qa does
    # (John, 2026-10-11): a clean analyzer run at HEAD, or it stays pending.
    Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex), at_head: true)

    call(frame(context, context.coder), EvaluateTask, %{task_id: task_id})
    context
  end

  @doc "QA takes the issue's QA task and submits a passing attempt."
  def qa_passes_it(context) do
    task_id = take(context, context.qa, "qa_complete")

    call(frame(context, context.qa), "submit_issue_qa_result", %{
      issue_id: context.issue_id,
      task_id: task_id,
      status: "pass",
      scenarios: [
        %{
          name: "The waiting agent receives its notification",
          status: "pass",
          observation: "Delivered a notification and observed it in the waiting agent's inbox."
        }
      ],
      issue_ids: []
    })

    context
  end

  @doc "What the coder is offered next, as it reads it."
  def the_coder_is_offered(context),
    do: call(frame(context, context.coder), "get_next_requirement", %{})

  @doc "The coder takes `promote_issue` and completes it. Returns the task's answer."
  def the_coder_promotes_it(context) do
    task_id = take(context, context.coder, "promote_issue")

    {:reply, response, _} =
      EvaluateTask.execute(%{task_id: task_id}, frame(context, context.coder))

    response_text(response)
  end

  @doc "The issue as main reads it."
  def the_issue(context), do: call(context.main_frame, "get_issue", %{issue_id: context.issue_id})

  @doc "Whether every teammate reads `Assignment: none` in main's listing."
  def the_team_is_free?(context) do
    entries = context.main_frame |> call(ListAgentWork, %{}) |> String.split("Agent: ")

    Enum.all?(context.team, fn agent ->
      entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
      entry && entry =~ "Assignment: none"
    end)
  end

  # The agent's next offer must be `requirement` on this issue; it starts it.
  defp take(context, agent, requirement) do
    offer = call(frame(context, agent), "get_next_requirement", %{})

    assert offer =~ "entity_id=`#{context.issue_id}`",
           "#{agent.role} was not offered issue #{context.issue_id}. Got: #{offer}"

    assert offer =~ "requirement_name=`#{requirement}`",
           "#{agent.role} was not offered #{requirement}. Got: #{offer}"

    started =
      call(frame(context, agent), StartTask, %{
        requirement_name: requirement,
        entity_type: "issue",
        entity_id: context.issue_id
      })

    extract_task_id!(started)
  end

  defp frame(context, agent),
    do: %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

  defp call(frame, name, params) when is_binary(name) do
    context = Map.put(frame.assigns, :scope, frame.assigns[:current_scope])

    case ToolLibrary.run(name, params, context) do
      {:ok, text} -> text
      {:error, text} -> flunk("#{name} refused: #{text}")
    end
  end

  defp call(frame, tool, params) do
    {:reply, response, _frame} = tool.execute(params, frame)
    refute response.isError, response_text(response)
    response_text(response)
  end
end
