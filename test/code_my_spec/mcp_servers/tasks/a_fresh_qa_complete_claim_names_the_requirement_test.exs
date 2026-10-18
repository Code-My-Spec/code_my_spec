defmodule CodeMySpec.McpServers.Tasks.AFreshQaCompleteClaimNamesTheRequirementTest do
  @moduledoc """
  542e01e7: an answered blocker told a QA agent to resume with
  `start_task(requirement_name: "qa_complete", entity_type: "story", entity_id:
  "963")`, but the task that notice was about had already been cancelled by the
  time the agent called back. `find_existing_task/3` only matches a task whose
  status is `:prepared`, `:active` or `:blocked`, so a cancelled task is not
  found as `existing` -- the call went through `handle_existing(nil, ...)`, the
  fresh-claim path, not the `:blocked` resume path `f7a4b81e` already fixed.
  `qa_eligible_to_start/3` then refused with a bare `:requirement_not_eligible`
  atom, which `TasksMapper.error/1` rendered as the literal string
  "requirement_not_eligible" -- no requirement named, no way forward.

  Reproduced directly rather than by replaying the whole notice/cancel
  sequence: any fresh `qa_complete` claim on a story that is not yet
  actionable for QA hits the same `handle_existing(nil, ...)` branch and the
  same bare refusal.
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  setup :synced_context_component

  defp text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.get("text")
  end

  test "a fresh qa_complete claim on a not-yet-actionable story names the requirement and points at get_next_requirement, not a bare atom",
       context do
    context = ProjectStateFixtures.apply_project_kickoff(context)

    story =
      StoryHelpers.create_and_link(context.scope, context.component.module_name,
        title: "A story whose QA notice outlived its own cancelled task",
        description: "Nothing has made qa_complete actionable yet.",
        acceptance_criteria: ["The stated behavior is implemented"]
      )

    qa = Fixtures.running_agent(context.scope, role: "qa")
    :ok = Agents.claim_story(context.scope, qa, story.id)

    frame = %Frame{assigns: %{current_scope: context.scope, agent_id: qa.id}}

    params = %{
      requirement_name: "qa_complete",
      entity_type: "story",
      entity_id: to_string(story.number)
    }

    {:reply, result, _} = StartTask.execute(params, frame)

    assert result.isError,
           "start_task should refuse a qa_complete claim that is not yet actionable: #{inspect(result)}"

    body = text(result)

    refute body == "requirement_not_eligible",
           "the bare atom string leaked through unexplained: #{body}"

    assert body =~ "qa_complete for story "
    assert body =~ "get_next_requirement"
    assert body =~ "not eligible"
  end
end
