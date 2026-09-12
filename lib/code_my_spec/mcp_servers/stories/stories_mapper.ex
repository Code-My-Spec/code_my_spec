defmodule CodeMySpec.McpServers.Stories.StoriesMapper do
  @moduledoc """
  Maps story data to MCP responses using a hybrid format:
  human-readable summary + JSON data for programmatic access.
  """

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Formatters

  # ---------------------------------------------------------------------------
  # Tool Responses (hybrid format: summary + JSON)
  # ---------------------------------------------------------------------------

  def story_response(story) do
    data = story_data(story)
    summary = "Story created: \"#{story.title}\" (ID: #{story.id})"

    hybrid_response(summary, data)
  end

  def story_updated_response(story) do
    data = story_data(story)
    summary = "Story updated: \"#{story.title}\" (ID: #{story.id})"

    hybrid_response(summary, data)
  end

  def story_get_response(story) do
    data = story_data(story)
    criteria_count = length(story.criteria || [])
    verified_count = Enum.count(story.criteria || [], & &1.verified)
    tags_line = tags_line(story)
    criteria_lines = format_criteria_text(story.criteria)
    notes_line = notes_line(story.notes)
    component_line = component_line(story.component)

    summary = """
    ## #{story.title} (ID: #{story.id})#{number_line(story)}

    #{story.story || story.description || "No story"}#{notes_line}#{component_line}

    Ready for development: #{story.ready_for_dev == true}

    **Acceptance Criteria:** #{criteria_count} total, #{verified_count} verified#{tags_line}

    #{criteria_lines}
    """

    hybrid_response(String.trim(summary), data)
  end

  # Extracted from `story_get_response/1`, which was building four optional
  # fragments inline and came to a cyclomatic complexity of 12. Each of these is
  # one question with one answer.
  defp tags_line(story) do
    story
    |> story_tags()
    |> Enum.map_join(", ", & &1.name)
    |> case do
      "" -> ""
      names -> "\n**Tags:** #{names}"
    end
  end

  defp story_tags(%{tags: tags} = story) do
    if Ecto.assoc_loaded?(story.tags), do: tags, else: []
  end

  # The durable number, beside the primary key.
  #
  # Both, because they are different things and each is load-bearing somewhere:
  # every tool takes the id, and the spex directory a story's specs live in is
  # `test/spex/<number>_<slug>/` — which `Parser.derive_story_number/1` reads
  # back to decide whose story a failing spec belongs to.
  #
  # Nothing exposed the number until now, so an agent told to write spex for a
  # story had no way to learn the one part of the path that identifies it, and
  # a directory named from the id points the gate at a different story or at
  # none. `story_id_from_path/2`'s own comment records that going wrong:
  # `test/spex/811_…` derives 811, a real but unrelated story.
  defp number_line(%{number: number}) when is_integer(number), do: " · story #{number}"
  defp number_line(_story), do: ""

  defp notes_line(nil), do: ""
  defp notes_line(""), do: ""
  defp notes_line(notes), do: "\n\n**Notes:** #{notes}"

  defp component_line(%{module_name: module_name}), do: "\n\n**Component:** #{module_name}"
  defp component_line(_), do: ""

  def story_deleted_response(story) do
    Response.tool()
    |> Response.text("Story deleted: \"#{story.title}\" (ID: #{story.id})")
  end

  def story_component_set_response(story) do
    data = story_data(story)

    summary =
      "Component assigned to story: \"#{story.title}\" (ID: #{story.id}) -> Component #{story.component_id}"

    hybrid_response(summary, data)
  end

  def story_component_cleared_response(story) do
    data = story_data(story)
    summary = "Component cleared from story: \"#{story.title}\" (ID: #{story.id})"

    hybrid_response(summary, data)
  end

  def stories_list_response(stories, total, limit, offset) do
    count = length(stories)
    summaries = Enum.map(stories, &story_summary/1)

    summary_text =
      if count == 0 do
        if offset > 0 do
          "No more stories. Showing #{offset + 1}-#{offset} of #{total} total."
        else
          "No stories found."
        end
      else
        story_lines =
          Enum.map_join(stories, "\n", fn s -> "- #{s.title} (ID: #{s.id})" end)

        range_start = offset + 1
        range_end = offset + count

        pagination_hint =
          if total > range_end do
            "\n\n*Use offset: #{range_end} to see more (#{total - range_end} remaining)*"
          else
            ""
          end

        "Showing #{range_start}-#{range_end} of #{total} stories:\n#{story_lines}#{pagination_hint}"
      end

    data = %{
      stories: summaries,
      total: total,
      limit: limit,
      offset: offset,
      has_more: total > offset + count
    }

    hybrid_response(summary_text, data)
  end

  def story_titles_response(titles) do
    count = length(titles)

    summary_text =
      if count == 0 do
        "No stories found."
      else
        title_lines =
          Enum.map_join(titles, "\n", fn t -> "- #{t.title} (ID: #{t.id})" end)

        "#{count} stories:\n#{title_lines}"
      end

    hybrid_response(summary_text, %{stories: titles, count: count})
  end

  def prompt_response(prompt) do
    Response.tool()
    |> Response.text(prompt)
  end

  # ---------------------------------------------------------------------------
  # Tag Responses
  # ---------------------------------------------------------------------------

  def tag_added_response(story, tag) do
    summary = "Tag '#{tag.name}' added to story \"#{story.title}\" (ID: #{story.id})"
    data = %{story_id: story.id, tag: tag.name}
    hybrid_response(summary, data)
  end

  def tag_already_exists_response(story, tag) do
    summary = "Story \"#{story.title}\" already has tag '#{tag.name}'"
    data = %{story_id: story.id, tag: tag.name, already_exists: true}
    hybrid_response(summary, data)
  end

  def tag_removed_response(story, tag_name) do
    Response.tool()
    |> Response.text("Tag '#{tag_name}' removed from story \"#{story.title}\" (ID: #{story.id})")
  end

  def story_tags_response(story, tags) do
    tag_names = Enum.map(tags, & &1.name)
    count = length(tags)

    summary =
      if count == 0 do
        "Story \"#{story.title}\" has no tags."
      else
        tag_list = Enum.join(tag_names, ", ")
        "Story \"#{story.title}\" has #{count} tag(s): #{tag_list}"
      end

    data = %{story_id: story.id, tags: tag_names, count: count}
    hybrid_response(summary, data)
  end

  def stories_by_tag_response(stories, tag_name) do
    count = length(stories)

    summary =
      if count == 0 do
        "No stories found with tag '#{tag_name}'."
      else
        story_lines =
          Enum.map_join(stories, "\n", fn s -> "- #{s.title} (ID: #{s.id})" end)

        "#{count} stories with tag '#{tag_name}':\n#{story_lines}"
      end

    data = %{
      tag: tag_name,
      count: count,
      stories: Enum.map(stories, fn s -> %{id: s.id, title: s.title} end)
    }

    hybrid_response(summary, data)
  end

  def project_tags_response(tags) do
    count = length(tags)
    tag_names = Enum.map(tags, & &1.name)

    summary =
      if count == 0 do
        "No tags found in this project. Use update_story with tags field to add tags."
      else
        tag_list = Enum.map_join(tags, "\n", fn t -> "- #{t.name}" end)
        "#{count} tags in project:\n#{tag_list}"
      end

    hybrid_response(summary, %{tags: tag_names, count: count})
  end

  def bulk_tag_response(successes, failures, tag_name) do
    success_count = length(successes)
    failure_count = length(failures)

    summary =
      cond do
        failure_count == 0 ->
          "Tagged #{success_count} stories with '#{tag_name}'."

        success_count == 0 ->
          failed_ids = Enum.map_join(failures, ", ", fn {:error, id, _} -> id end)
          "Failed to tag stories. Not found: #{failed_ids}"

        true ->
          failed_ids = Enum.map_join(failures, ", ", fn {:error, id, _} -> id end)
          "Tagged #{success_count} stories with '#{tag_name}'. Not found: #{failed_ids}"
      end

    data = %{
      tag: tag_name,
      success_count: success_count,
      failure_count: failure_count,
      tagged_story_ids: successes,
      not_found_ids: Enum.map(failures, fn {:error, id, _} -> id end)
    }

    hybrid_response(summary, data)
  end

  # ---------------------------------------------------------------------------
  # Criterion Responses
  # ---------------------------------------------------------------------------

  def criterion_added_response(criterion, story) do
    data = criterion_data(criterion)

    summary =
      "Criterion added to \"#{story.title}\" (ID: #{criterion.id}): #{criterion.description}"

    hybrid_response(summary, data)
  end

  def criterion_updated_response(criterion) do
    data = criterion_data(criterion)
    summary = "Criterion updated (ID: #{criterion.id}): #{criterion.description}"

    hybrid_response(summary, data)
  end

  def criterion_deleted_response(criterion) do
    Response.tool()
    |> Response.text("Criterion deleted (ID: #{criterion.id}): #{criterion.description}")
  end

  def criterion_moved_response(criterion, from_story, to_story) do
    data = criterion_data(criterion)

    summary =
      "Criterion moved (ID: #{criterion.id}): \"#{from_story.title}\" (ID: #{from_story.id}) -> \"#{to_story.title}\" (ID: #{to_story.id})"

    hybrid_response(summary, data)
  end

  def criterion_not_found_error do
    Response.tool()
    |> Response.error("Criterion not found. Use get_story to see criteria IDs.")
  end

  # ---------------------------------------------------------------------------
  # Error Responses
  # ---------------------------------------------------------------------------

  def validation_error(changeset) do
    Response.tool()
    |> Response.error(Formatters.format_changeset_errors(changeset))
  end

  # A changeset reaching `error/1` used to match no clause, so the tool crashed
  # with `function_clause` and the caller got `-32603 Tool execution crashed` —
  # nothing about which field was invalid, or that validation was even involved.
  # `set_story_component` hit it on a story whose `story` narrative was blank:
  # the update touched only `component_id`, but the changeset requires the
  # narrative, so every attempt died with an internal error.
  #
  # Delegating rather than duplicating: `validation_error/1` already renders
  # changesets, and the only thing missing was a route to it.
  def error(%Ecto.Changeset{} = changeset), do: validation_error(changeset)

  def error(error) when is_atom(error), do: error |> to_string() |> error()

  def error(error) when is_binary(error) do
    Response.tool()
    |> Response.error(error)
  end

  def not_found_error do
    Response.tool()
    |> Response.error("Story not found. Verify the story ID exists using list_stories.")
  end

  # ---------------------------------------------------------------------------
  # Resource Responses
  # ---------------------------------------------------------------------------

  def story_resource(story) do
    Response.resource()
    |> Response.json(story_data(story))
  end

  def stories_list_resource(stories) do
    Response.resource()
    |> Response.json(%{stories: Enum.map(stories, &story_summary/1)})
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp hybrid_response(summary, _data) do
    Response.tool()
    |> Response.text(summary)
  end

  defp story_data(story) do
    base = %{
      id: story.id,
      title: story.title,
      story: story.story || story.description,
      notes: story.notes,
      description: story.description,
      ready_for_dev: story.ready_for_dev == true,
      epic_id: story.epic_id,
      acceptance_criteria: criteria_descriptions(story),
      criteria: format_criteria(story.criteria),
      component_id: story.component_id,
      priority: story.priority
    }

    if Ecto.assoc_loaded?(story.tags) do
      Map.put(base, :tags, Enum.map(story.tags, & &1.name))
    else
      base
    end
  end

  defp story_summary(story) do
    base = %{
      id: story.id,
      title: story.title,
      story: story.story || story.description,
      notes: story.notes,
      description: story.description,
      ready_for_dev: story.ready_for_dev == true,
      epic_id: story.epic_id,
      component_id: story.component_id,
      priority: story.priority
    }

    base =
      if Ecto.assoc_loaded?(story.criteria) do
        Map.put(base, :criteria, format_criteria(story.criteria))
      else
        base
      end

    if Ecto.assoc_loaded?(story.tags) do
      Map.put(base, :tags, Enum.map(story.tags, & &1.name))
    else
      base
    end
  end

  defp criteria_descriptions(story) do
    case story.criteria do
      criteria when is_list(criteria) and criteria != [] ->
        Enum.map(criteria, & &1.description)

      _ ->
        story.acceptance_criteria || []
    end
  end

  defp format_criteria_text(criteria) when is_list(criteria) and criteria != [] do
    Enum.map_join(criteria, "\n", fn c ->
      status = if c.verified, do: "[x]", else: "[ ]"
      "- #{status} #{c.description} (criterion #{c.id})"
    end)
  end

  defp format_criteria_text(_), do: "_No criteria defined._"

  defp format_criteria(criteria) when is_list(criteria) do
    Enum.map(criteria, &criterion_data/1)
  end

  defp format_criteria(_), do: []

  defp criterion_data(c) do
    %{
      id: c.id,
      description: c.description,
      story_id: c.story_id,
      verified: c.verified,
      verified_at: c.verified_at
    }
  end
end
