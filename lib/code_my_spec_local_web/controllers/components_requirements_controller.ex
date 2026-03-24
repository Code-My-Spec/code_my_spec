defmodule CodeMySpecLocalWeb.ComponentsRequirementsController do
  @moduledoc """
  LLM API for component requirements status.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Components
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements

  def index(conn, _params) do
    scope = conn.assigns.current_scope

    components =
      Components.list_components(scope)
      |> Repo.preload(:requirements)

    lines =
      Enum.map_join(components, "\n", fn component ->
        reqs = component.requirements || []
        total = length(reqs)
        satisfied = Enum.count(reqs, & &1.satisfied)
        check = if satisfied == total and total > 0, do: "[x]", else: "[ ]"
        "- #{check} **#{component.module_name}** (#{satisfied}/#{total}) — type: #{component.type}, id: #{component.id}"
      end)

    text(conn, "# Components\n\n#{lines}\n")
  end

  def show(conn, %{"component_id" => component_id}) do
    scope = conn.assigns.current_scope

    component =
      Components.get_component!(scope, component_id)
      |> Repo.preload([:requirements, :dependencies])

    reqs = component.requirements || []
    actionable = Requirements.next_actionable(scope, component)
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

    deps_info =
      case component.dependencies do
        deps when is_list(deps) and deps != [] ->
          dep_lines = Enum.map_join(deps, "\n", fn dep -> "- #{dep.module_name}" end)
          "\n\n## Dependencies\n\n#{dep_lines}"
        _ -> ""
      end

    text(conn, "# #{component.module_name} — Requirements (#{satisfied}/#{total})\n\nType: #{component.type}#{deps_info}\n\n#{lines}\n")
  end

  def show_requirement(conn, %{"component_id" => component_id, "name" => name}) do
    scope = conn.assigns.current_scope

    component =
      Components.get_component!(scope, component_id)
      |> Repo.preload(:requirements)

    requirement = Enum.find(component.requirements, &(&1.name == name))

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
