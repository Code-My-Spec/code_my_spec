defmodule CodeMySpec.Requirements.StoryIssueGraph do
  @moduledoc "Story-owned issue submission branches, written with the story's graph family."

  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Requirements.{Requirement, RequirementDefinitionData}

  def issues(story, ctx, config) do
    ctx
    |> offered(config)
    |> Enum.filter(&(&1.story_id == story.id))
    |> Enum.sort_by(& &1.id)
  end

  @doc "Every story issue with a branch in the graph: the ones offering a fix."
  def offered(ctx, config) do
    threshold = Map.get(config, :fix_issues_min_severity) || :medium
    ctx |> Map.get(:story_issues, []) |> Enum.filter(&Issue.fix_offered?(&1, threshold))
  end

  def nodes(story, ctx, config, fingerprint \\ nil) do
    [definition] = RequirementDefinitionData.story_issue_graph()

    Enum.map(issues(story, ctx, config), fn issue ->
      %Requirement{
        entity_type: "issue",
        entity_id: issue.id,
        entity_name: issue.title,
        name: definition.name,
        description: definition.description,
        satisfied: not is_nil(issue.story_submission_ref),
        satisfied_by: definition.satisfied_by,
        role: :coding,
        parent_entity_id: story.id,
        parent_entity_name: story.title,
        inputs_fingerprint: fingerprint,
        details: %{
          "story_id" => story.id,
          "scope" => to_string(issue.scope),
          "severity" => to_string(issue.severity),
          "submission_ref" => issue.story_submission_ref,
          "revision" => issue.story_submission_revision,
          "evidence" => issue.story_submission_evidence
        }
      }
    end)
  end

  def edges(story, ctx, config) do
    Enum.flat_map(issues(story, ctx, config), fn issue ->
      submitted = {"issue", issue.id, "submitted"}

      [
        %{from: {"story", story.id, "story_issues_triaged"}, to: submitted},
        %{from: submitted, to: {"story", story.id, "ready_for_qa"}}
      ]
    end)
  end
end
