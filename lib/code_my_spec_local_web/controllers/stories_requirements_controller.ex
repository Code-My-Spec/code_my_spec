defmodule CodeMySpecLocalWeb.StoriesRequirementsController do
  @moduledoc """
  LLM API for story requirements status.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Stories

  def index(conn, _params) do
    scope = conn.assigns.current_scope

    case Stories.list_project_stories(scope) do
      {:ok, stories} ->
        stories = Repo.preload(stories, :requirements)

        lines =
          Enum.map_join(stories, "\n", fn story ->
            reqs = story.requirements || []
            total = length(reqs)
            satisfied = Enum.count(reqs, & &1.satisfied)
            check = if satisfied == total and total > 0, do: "[x]", else: "[ ]"
            "- #{check} **#{story.title}** (#{satisfied}/#{total}) — id: #{story.id}"
          end)

        text(conn, "# Stories\n\n#{lines}\n")

      _ ->
        text(conn, "# Stories\n\nNo stories found.\n")
    end
  end

  def show(conn, %{"story_id" => story_id}) do
    scope = conn.assigns.current_scope

    case Stories.get_story(scope, story_id) do
      story when not is_nil(story) ->
        story = Repo.preload(story, [:requirements, :component])
        reqs = story.requirements || []
        actionable = Requirements.next_actionable(scope, story)
        total = length(reqs)
        satisfied = Enum.count(reqs, & &1.satisfied)

        actionable_names =
          actionable |> Map.values() |> List.flatten() |> MapSet.new(& &1.name)

        lines =
          Enum.map_join(reqs, "\n", fn req ->
            check = if req.satisfied, do: "[x]", else: "[ ]"
            tag = if MapSet.member?(actionable_names, req.name), do: " (actionable)", else: ""
            "- #{check} **#{req.name}** — #{req.description}#{tag}"
          end)

        component_info =
          if story.component do
            "\n\nLinked component: #{story.component.module_name}"
          else
            "\n\nNo component linked."
          end

        text(conn, "# #{story.title} — Requirements (#{satisfied}/#{total})\n\n#{lines}#{component_info}\n")

      nil ->
        conn |> put_status(404) |> text("Story not found: #{story_id}")
    end
  end

  def show_requirement(conn, %{"story_id" => story_id, "name" => name}) do
    scope = conn.assigns.current_scope
    story = Stories.get_story!(scope, story_id) |> Repo.preload(:requirements)
    requirement = Enum.find(story.requirements, &(&1.name == name))

    if requirement do
      text(conn, render_requirement(requirement, scope))
    else
      conn |> put_status(404) |> text("Requirement not found: #{name}")
    end
  end

  defp render_requirement(req, scope) do
    status = if req.satisfied, do: "satisfied", else: "not satisfied"
    score = if req.score, do: " (score: #{Float.round(req.score, 2)})", else: ""

    prompt =
      if req.satisfied_by && !req.satisfied do
        case req.satisfied_by.command(scope, %{}) do
          {:ok, text} -> "\n\n## Prompt\n\n#{text}"
          _ -> ""
        end
      else
        ""
      end

    deps =
      case req.depends_on do
        edges when is_list(edges) and edges != [] ->
          lines = Enum.map_join(edges, "\n", fn e ->
            "- #{e["entity_type"]}:#{e["entity_id"]} → #{e["requirement_name"]}"
          end)
          "\n\n## Dependencies\n\n#{lines}"
        _ -> ""
      end

    "# #{req.name}\n\n#{req.description}\n\nStatus: #{status}#{score}#{deps}#{prompt}\n"
  end
end
