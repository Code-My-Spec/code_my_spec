defmodule CodeMySpecSpex.StoryBoundHelpers do
  @moduledoc """
  A team bound to its story, for story 1016's criteria 1749-1754 (4292518a):
  what each agent is offered through `get_next_requirement`, and what
  `start_task` lets it claim.
  """

  import ExUnit.Assertions

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  @doc """
  A coding and a QA agent on the scope's copy, a project whose story has
  coding's part done and QA's open, and that story made the team's active
  story through `set_active_story` (unless `active?: false`).
  """
  @spec team_on_a_story(map(), keyword()) :: map()
  def team_on_a_story(context, opts \\ []) do
    coding = Fixtures.running_agent(context.scope, role: "coding")
    qa = Fixtures.running_agent(context.scope, role: "qa")

    context =
      context
      |> Map.merge(%{coding: coding, qa: qa, team: [coding, qa]})
      |> FullSatisfactionFixtures.apply_without_qa_story()

    if Keyword.get(opts, :active?, true), do: Slice.activate(context), else: context
  end

  @doc "An issue reported and accepted as a bug, filed against `story` or nothing."
  @spec issue_accepted(map(), map() | nil) :: map()
  def issue_accepted(context, story \\ nil) do
    issue = Fixtures.issue_fixture(context.scope, %{title: "Broken thing", severity: :high})

    params =
      case story do
        nil -> %{issue_id: issue.id, category: "bug"}
        %{number: number} -> %{issue_id: issue.id, category: "bug", story_number: number}
      end

    reply =
      ToolLibrary.run(
        "accept_issue",
        params,
        Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
      )

    assert match?({:ok, _}, reply), response_text(reply)
    context
  end

  @doc "The project's QA plan is gone, so project-level `qa_setup` is unsatisfied again."
  @spec qa_plan_missing(map()) :: map()
  def qa_plan_missing(context) do
    :ok = CodeMySpec.Environments.delete_file(context.environment, ".code_my_spec/qa/plan.md")

    reply =
      ToolLibrary.run(
        "sync_project",
        %{},
        Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
      )

    assert match?({:ok, _}, reply), response_text(reply)
    context
  end

  @doc "What `get_next_requirement` tells `agent`."
  @spec next_for(map(), map()) :: String.t()
  def next_for(context, agent), do: Slice.next(context, %{agent_id: agent.id})

  @doc "Whether `text` offers requirement `name` (exactly, not as a suffix of another)."
  @spec offers?(String.t(), String.t()) :: boolean()
  def offers?(text, name) do
    text =~ "requirement_name=`#{name}`" or text =~ ~r/^- #{name} \(/m
  end

  @doc "`agent` starts project-level `name`: `{error?, text}`."
  @spec start_project(map(), map(), String.t()) :: {boolean(), String.t()}
  def start_project(context, agent, name) do
    Slice.attempt(
      context,
      "start_task",
      %{
        requirement_name: name,
        entity_type: "project",
        entity_id: to_string(context.scope.active_project_id)
      },
      %{agent_id: agent.id}
    )
  end

  defp frame(context), do: %Frame{assigns: %{current_scope: context.scope}}
end
