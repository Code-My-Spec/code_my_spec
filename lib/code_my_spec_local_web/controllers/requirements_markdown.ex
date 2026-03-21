defmodule CodeMySpecLocalWeb.RequirementsMarkdown do
  @moduledoc """
  Markdown rendering for requirements API (LLM interface).
  """

  def index(%{project: project, requirements: requirements, actionable: actionable}) do
    name = project.name || "Project"
    total = length(requirements)
    satisfied = Enum.count(requirements, & &1.satisfied)

    grouped =
      requirements
      |> Enum.sort_by(& &1.name)
      |> Enum.group_by(& &1.artifact_type)

    actionable_names =
      actionable
      |> Map.values()
      |> List.flatten()
      |> MapSet.new(& &1.name)

    sections =
      Enum.map_join(grouped, "\n\n", fn {type, reqs} ->
        lines =
          Enum.map_join(reqs, "\n", fn req ->
            check = if req.satisfied, do: "[x]", else: "[ ]"
            actionable_tag = if MapSet.member?(actionable_names, req.name), do: " (actionable)", else: ""
            "- #{check} **#{req.name}** — #{req.description}#{actionable_tag}"
          end)

        "## #{type}\n\n#{lines}"
      end)

    "# #{name} — Requirements (#{satisfied}/#{total})\n\n#{sections}\n"
  end

  def show(%{requirement: req}) do
    status = if req.satisfied, do: "satisfied", else: "not satisfied"
    score = if req.score, do: " (score: #{Float.round(req.score, 2)})", else: ""

    details =
      if req.details != %{} do
        "\n\n## Details\n\n```json\n#{Jason.encode!(req.details, pretty: true)}\n```"
      else
        ""
      end

    satisfied_by =
      if req.satisfied_by do
        "\n\nSatisfied by: `#{inspect(req.satisfied_by)}`"
      else
        ""
      end

    checked_at =
      if req.checked_at do
        "\n\nLast checked: #{Calendar.strftime(req.checked_at, "%Y-%m-%d %H:%M:%S UTC")}"
      else
        ""
      end

    "# #{req.name}\n\n#{req.description}\n\nStatus: #{status}#{score}#{satisfied_by}#{details}#{checked_at}\n"
  end
end
