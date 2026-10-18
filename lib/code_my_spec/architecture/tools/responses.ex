defmodule CodeMySpec.Architecture.Tools.Responses do
  @moduledoc false

  alias CodeMySpec.Architecture.StoryAnalyzer

  def story_analysis_response(analysis) do
    markdown = StoryAnalyzer.format_as_markdown(analysis)

    {:ok, markdown}
  end

  # Proposal responses
  def proposal_created(proposal) do
    {:ok,
     JSON.encode!(%{
       success: true,
       message: "Architecture proposal created",
       proposal: format_proposal(proposal)
     })}
  end

  def proposal_validated(result) do
    case result do
      {:ok, proposal} ->
        {:ok,
         JSON.encode!(%{
           valid: true,
           message: "Proposal is valid and ready for execution",
           proposal: format_proposal(proposal)
         })}

      {:error, errors} ->
        {:ok,
         JSON.encode!(%{
           valid: false,
           message: "Proposal has validation errors",
           errors: errors
         })}
    end
  end

  def proposal_executed(result, dry_run) do
    {:ok,
     JSON.encode!(%{
       success: true,
       dry_run: dry_run,
       message:
         if(dry_run,
           do: "Dry run complete - no changes made",
           else: "Proposal executed successfully"
         ),
       created_contexts: result.created_contexts,
       created_components: result.created_components,
       linked_stories: result.linked_stories
     })}
  end

  defp format_proposal(proposal) do
    %{
      contexts: Enum.map(proposal.contexts, &format_proposal_context/1),
      surface_components: Enum.map(proposal.surface_components, &format_proposal_component/1),
      unmapped_story_ids: proposal.unmapped_story_ids
    }
  end

  defp format_proposal_context(ctx) do
    %{
      name: ctx.name,
      description: ctx.description,
      children: Enum.map(ctx.children, &format_proposal_component/1),
      story_ids: ctx.story_ids
    }
  end

  defp format_proposal_component(comp) do
    %{
      name: comp.name,
      type: comp.type,
      description: comp.description,
      story_ids: Map.get(comp, :story_ids, [])
    }
  end

  def architecture_summary_response(summary) do
    {:ok, JSON.encode!(summary)}
  end

  def component_impact_response(impact) do
    {:ok,
     JSON.encode!(%{
       component: component_summary(impact.component),
       direct_dependents: Enum.map(impact.direct_dependents, &component_summary/1),
       transitive_dependents: Enum.map(impact.transitive_dependents, &component_summary/1),
       affected_contexts: Enum.map(impact.affected_contexts, &component_summary/1)
     })}
  end

  def component_view_response(markdown) do
    {:ok, markdown}
  end

  def validation_result_response(:ok) do
    {:ok,
     JSON.encode!(%{
       valid: true,
       message: "No circular dependencies detected"
     })}
  end

  def validation_result_response({:error, cycles}) do
    formatted_cycles =
      Enum.map(cycles, fn cycle ->
        %{
          path: cycle.path,
          components:
            Enum.map(cycle.components, fn comp ->
              %{
                id: comp.id,
                name: comp.name,
                type: comp.type,
                module_name: comp.module_name
              }
            end)
        }
      end)

    {:ok,
     JSON.encode!(%{
       valid: false,
       message: "Circular dependencies detected",
       cycles: formatted_cycles
     })}
  end

  def prompt_response(prompt) do
    {:ok, prompt}
  end

  def drift_response(:off) do
    {:ok, "# Architecture Check\n\nArchitecture checking is off for this project.\n"}
  end

  def drift_response(drift) do
    {:ok, format_drift(drift)}
  end

  defp format_drift(drift) do
    sections =
      [
        format_section(
          "Unplanned dependencies",
          drift.unplanned_dependencies,
          &"#{&1.source_component.module_name} depends on #{&1.target_component.module_name}, which was never planned."
        ),
        format_section(
          "Planned dependencies not used in code",
          drift.unused_dependencies,
          &"#{&1.source_component.module_name} is planned to depend on #{&1.target_component.module_name}, but the code never calls it."
        ),
        format_section(
          "Planned components with no code",
          drift.missing_code,
          &"#{&1.module_name} is planned but has no code."
        ),
        format_section(
          "Code with no planned owner",
          drift.unowned_code,
          &"#{&1.module_name} exists in code but has no planned component."
        )
      ]
      |> Enum.reject(&(&1 == ""))

    case sections do
      [] -> "# Architecture Check\n\nNo drift found.\n"
      _ -> "# Architecture Check\n\n" <> Enum.join(sections, "\n\n")
    end
  end

  defp format_section(_title, [], _line_fn), do: ""

  defp format_section(title, items, line_fn) do
    lines = Enum.map_join(items, "\n", &"- #{line_fn.(&1)}")
    "## #{title}\n\n#{lines}"
  end

  def validation_error(changeset) do
    {:error, CodeMySpec.Tools.changeset_errors(changeset)}
  end

  def error(error) when is_atom(error), do: error |> to_string() |> error()

  def error(error) when is_binary(error) do
    {:error, error}
  end

  def error(%Ecto.Changeset{} = changeset) do
    validation_error(changeset)
  end

  def not_found_error do
    {:error, "Resource not found"}
  end

  defp component_summary(component) do
    %{
      id: component.id,
      name: component.name,
      type: component.type,
      module_name: component.module_name,
      description: component.description
    }
  end
end
