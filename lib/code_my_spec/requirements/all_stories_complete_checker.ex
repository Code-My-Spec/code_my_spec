defmodule CodeMySpec.Requirements.AllStoriesCompleteChecker do
  @moduledoc """
  Checks whether all stories in a project have all their requirements satisfied.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  import Ecto.Query

  def check(
        %Scope{} = _scope,
        %RequirementDefinition{
          name: name,
          artifact_type: artifact_type,
          description: description,
          checker: checker,
          satisfied_by: satisfied_by
        },
        %Project{} = project,
        _opts \\ []
      ) do
    stories =
      Story
      |> where([s], s.project_id == ^project.id)
      |> Repo.all()
      |> Repo.preload(:requirements)

    story_requirement_names =
      RequirementsRegistry.get_story_requirements()
      |> Enum.map(& &1.name)

    {satisfied, details, depends_on} = evaluate_stories(stories, story_requirement_names)

    %{
      name: name,
      artifact_type: artifact_type,
      description: description,
      checker_module: checker,
      satisfied_by: satisfied_by,
      satisfied: satisfied,
      score: if(satisfied, do: 1.0, else: 0.0),
      checked_at: DateTime.utc_now(),
      details: details,
      depends_on: depends_on
    }
  end

  defp evaluate_stories([], _story_requirement_names) do
    {false, %{reason: "No stories found in project"}, []}
  end

  defp evaluate_stories(stories, story_requirement_names) do
    incomplete =
      Enum.reject(stories, fn story ->
        story_satisfied?(story, story_requirement_names)
      end)

    # Build depends_on edges to each story's terminal requirement (qa_complete)
    depends_on =
      Enum.map(stories, fn story ->
        %{
          "entity_type" => "story",
          "entity_id" => story.id,
          "requirement_name" => "qa_complete"
        }
      end)

    if incomplete == [] do
      {true, %{story_count: length(stories), all_complete: true}, depends_on}
    else
      {false,
       %{
         story_count: length(stories),
         incomplete_count: length(incomplete),
         incomplete_story_ids: Enum.map(incomplete, & &1.id)
       }, depends_on}
    end
  end

  defp story_satisfied?(story, story_requirement_names) do
    reqs = story.requirements || []
    satisfaction_map = Map.new(reqs, &{&1.name, &1.satisfied})

    Enum.all?(story_requirement_names, fn req_name ->
      Map.get(satisfaction_map, req_name, false)
    end)
  end
end
