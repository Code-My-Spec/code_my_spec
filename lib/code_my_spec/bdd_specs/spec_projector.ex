defmodule CodeMySpec.BddSpecs.SpecProjector do
  @moduledoc """
  Renders parsed Spec structs into various output formats.

  Provides summary views optimized for AI context windows (names and step descriptions only),
  full views with complete detail, and coverage maps that aggregate specs by story or criterion.
  Used to give agents visibility into BDD coverage without consuming context on implementation code.
  """

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.BddSpecs.{Scenario, Spec, Step}
  alias CodeMySpec.Stories.Story

  @doc """
  Returns a formatted coverage report showing spec coverage across stories.

  This is the main entry point for generating coverage reports. It groups specs
  by story and shows which acceptance criteria are covered.

  ## Examples

      iex> format_coverage([], [])
      "# BDD Spec Coverage\\n\\nNo stories found.\\n"

      iex> stories = [%Story{title: "Login", criteria: []}]
      iex> format_coverage(stories, [])
      "# BDD Spec Coverage\\n\\n..."

  """
  @spec format_coverage([Story.t()], [Spec.t()]) :: String.t()
  def format_coverage(stories, specs) do
    header = "# BDD Spec Coverage\n\n"

    body =
      if Enum.empty?(stories) do
        "No stories found.\n"
      else
        # Group specs by story_id
        specs_by_story = Enum.group_by(specs, & &1.story_id)

        # Generate coverage report for each story
        story_sections =
          stories
          |> Enum.map(fn story ->
            story_specs = Map.get(specs_by_story, story.id, [])
            format_story_with_criteria(story, story_specs)
          end)
          |> Enum.join("\n\n")

        # Add summary statistics
        total_stories = length(stories)
        stories_with_specs =
          stories
          |> Enum.count(fn story ->
            length(Map.get(specs_by_story, story.id, [])) > 0
          end)

        summary = """
        ## Summary

        - **Total Stories**: #{total_stories}
        - **Stories with Specs**: #{stories_with_specs}
        - **Coverage**: #{if total_stories > 0, do: Float.round(stories_with_specs / total_stories * 100, 1), else: 0}%

        """

        summary <> "\n" <> story_sections
      end

    header <> body
  end

  @doc """
  Returns a compact summary view of a single spec showing only names and step descriptions.

  Excludes implementation code and focuses on test structure for AI context consumption.

  ## Examples

      iex> spec = %Spec{name: "User auth", file_path: "/path/spec.exs", scenarios: []}
      iex> project_summary(spec)
      "# User auth\\n\\n..."

  """
  @spec project_summary(Spec.t()) :: String.t()
  def project_summary(%Spec{} = spec) do
    header = "# #{spec.name}\n\n"

    scenarios_text =
      Enum.map_join(spec.scenarios, "\n\n", &format_scenario_summary/1)

    header <> scenarios_text
  end

  @doc """
  Returns a summary view of multiple specs as a formatted list.

  ## Examples

      iex> project_summary_list([])
      ""

      iex> specs = [%Spec{name: "Auth", file_path: "/path/auth.exs", scenarios: []}]
      iex> project_summary_list(specs)
      "# Auth\\n\\n"

  """
  @spec project_summary_list(list(Spec.t())) :: String.t()
  def project_summary_list([]), do: ""

  def project_summary_list(specs) when is_list(specs) do
    Enum.map_join(specs, "\n\n---\n\n", &project_summary/1)
  end

  @doc """
  Returns a detailed view of a spec with complete information including metadata.

  ## Examples

      iex> spec = %Spec{name: "Auth", file_path: "/path/spec.exs", story_id: 1}
      iex> project_full(spec)
      "# Auth\\n\\n**File**: /path/spec.exs\\n..."

  """
  @spec project_full(Spec.t()) :: String.t()
  def project_full(%Spec{} = spec) do
    header = "# #{spec.name}\n\n"
    metadata = format_metadata(spec)

    scenarios_text =
      Enum.map_join(spec.scenarios, "\n\n", &format_scenario_full/1)

    [header, metadata, scenarios_text]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @doc """
  Returns a coverage report showing specs grouped by story.

  ## Examples

      iex> project_coverage_by_story([], [])
      ""

  """
  @spec project_coverage_by_story(list(Spec.t()), list(Story.t())) :: String.t()
  def project_coverage_by_story([], []), do: ""

  def project_coverage_by_story([], stories) when is_list(stories) do
    format_stories_without_coverage(stories)
  end

  def project_coverage_by_story(specs, stories) when is_list(specs) and is_list(stories) do
    # Group specs by story_id
    specs_by_story = Enum.group_by(specs, & &1.story_id)

    story_sections =
      stories
      |> Enum.map(fn story ->
        story_specs = Map.get(specs_by_story, story.id, [])
        format_story_coverage(story, story_specs)
      end)

    story_sections
    |> Enum.join("\n\n")
  end

  @doc """
  Returns a coverage report showing which criteria have specs.

  ## Examples

      iex> project_coverage_by_criterion([], [])
      ""

  """
  @spec project_coverage_by_criterion(list(Spec.t()), list(Criterion.t())) :: String.t()
  def project_coverage_by_criterion([], []), do: ""

  def project_coverage_by_criterion(specs, criteria) when is_list(specs) and is_list(criteria) do
    # Group specs by criterion_id
    specs_by_criterion = Enum.group_by(specs, & &1.criterion_id)

    criterion_sections =
      criteria
      |> Enum.map(fn criterion ->
        criterion_specs = Map.get(specs_by_criterion, criterion.id, [])
        format_criterion_coverage(criterion, criterion_specs)
      end)

    criterion_sections
    |> Enum.join("\n")
  end

  @doc """
  Formats a single scenario into markdown representation.

  ## Examples

      iex> scenario = %Scenario{name: "Login", given_steps: ["user exists"], when_steps: ["user logs in"], then_steps: ["user sees dashboard"]}
      iex> format_scenario(scenario)
      "## Login\\n\\n**Given:**\\n- user exists\\n..."

  """
  @spec format_scenario(Scenario.t()) :: String.t()
  def format_scenario(%Scenario{} = scenario) do
    header = "## #{scenario.name}\n\n"

    steps_text =
      [
        format_step_group("Given", scenario.given_steps),
        format_step_group("When", scenario.when_steps),
        format_step_group("Then", scenario.then_steps)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    header <> steps_text
  end

  @doc """
  Formats a single step into markdown representation.

  ## Examples

      iex> step = %Step{type: :given, description: "user is logged in", line: 10}
      iex> format_step(step)
      "Given user is logged in (line 10)"

  """
  @spec format_step(Step.t()) :: String.t()
  def format_step(%Step{type: type, description: description, line: line}) do
    prefix = format_step_type(type)

    case line do
      nil -> "#{prefix} #{description}"
      line_num -> "#{prefix} #{description} (line #{line_num})"
    end
  end

  # Private helper functions

  defp format_story_with_criteria(story, specs) do
    header = "## #{story.title}\n\n"

    # Get criteria for this story (if preloaded)
    criteria = Map.get(story, :criteria, [])

    if Enum.empty?(specs) do
      status = "❌ **No specs found**\n\n"

      criteria_section =
        if Enum.empty?(criteria) do
          ""
        else
          "**Criteria:**\n" <>
            Enum.map_join(criteria, "\n", fn criterion ->
              "- ❌ #{criterion.description}"
            end) <> "\n"
        end

      header <> status <> criteria_section
    else
      # Get covered criterion IDs from specs
      covered_criterion_ids =
        specs
        |> Enum.map(& &1.criterion_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      # Build coverage status
      status =
        if Enum.empty?(criteria) do
          "✓ **#{length(specs)} spec(s)**\n\n"
        else
          covered_count = length(covered_criterion_ids)
          total_count = length(criteria)

          if covered_count == total_count do
            "✓ **Full coverage** (#{covered_count}/#{total_count} criteria)\n\n"
          else
            "⚠ **Partial coverage** (#{covered_count}/#{total_count} criteria)\n\n"
          end
        end

      # Build criteria section if criteria exist
      criteria_section =
        if Enum.empty?(criteria) do
          ""
        else
          "**Criteria:**\n" <>
            Enum.map_join(criteria, "\n", fn criterion ->
              marker = if criterion.id in covered_criterion_ids, do: "✓", else: "❌"
              "- #{marker} #{criterion.description}"
            end) <> "\n\n"
        end

      # Build specs section
      specs_section =
        "**Specs:**\n" <>
          Enum.map_join(specs, "\n", fn spec ->
            "- #{spec.name}"
          end) <> "\n"

      header <> status <> criteria_section <> specs_section
    end
  end

  defp format_scenario_summary(%Scenario{} = scenario) do
    header = "## #{scenario.name}\n"

    steps =
      [
        format_simple_step_group("Given", scenario.given_steps),
        format_simple_step_group("When", scenario.when_steps),
        format_simple_step_group("Then", scenario.then_steps)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    header <> steps
  end

  defp format_scenario_full(%Scenario{} = scenario) do
    parts = ["## #{scenario.name}"]

    # Add line number if present
    parts =
      if scenario.line_number do
        parts ++ ["**Line**: #{scenario.line_number}"]
      else
        parts
      end

    # Add tags if present
    parts =
      if scenario.tags != [] do
        tags_str = Enum.map_join(scenario.tags, ", ", &to_string/1)
        parts ++ ["**Tags**: #{tags_str}"]
      else
        parts
      end

    # Add steps
    steps_text =
      [
        format_step_group("Given", scenario.given_steps),
        format_step_group("When", scenario.when_steps),
        format_step_group("Then", scenario.then_steps)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    (parts ++ [steps_text])
    |> Enum.join("\n\n")
  end

  defp format_metadata(%Spec{} = spec) do
    parts = ["**File**: #{spec.file_path}"]

    parts =
      if spec.story_id do
        parts ++ ["**Story ID**: #{spec.story_id}"]
      else
        parts
      end

    parts =
      if spec.criterion_id do
        parts ++ ["**Criterion ID**: #{spec.criterion_id}"]
      else
        parts
      end

    parts =
      if spec.tags != [] do
        tags_str = Enum.map_join(spec.tags, ", ", &to_string/1)
        parts ++ ["**Tags**: #{tags_str}"]
      else
        parts
      end

    parts
    |> Enum.join("\n")
    |> Kernel.<>("\n\n")
  end

  defp format_step_group(_label, []), do: ""

  defp format_step_group(label, steps) when is_list(steps) do
    step_lines = steps |> Enum.map(&"- #{&1}")
    ["**#{label}:**" | step_lines] |> Enum.join("\n")
  end

  defp format_simple_step_group(_label, []), do: ""

  defp format_simple_step_group(label, steps) when is_list(steps) do
    step_lines = steps |> Enum.map(&"  - #{&1}")
    ["**#{label}:**" | step_lines] |> Enum.join("\n")
  end

  defp format_step_type(:given), do: "Given"
  defp format_step_type(:when), do: "When"
  defp format_step_type(:then), do: "Then"

  defp format_story_coverage(story, []) do
    "## #{story.title}\n\n✗ **Status**: Missing coverage - No specs found\n"
  end

  defp format_story_coverage(story, specs) do
    # Determine coverage status based on criteria
    coverage_status = determine_coverage_status(story, specs)

    header = "## #{story.title}\n\n"
    status = "#{coverage_status}\n\n"

    spec_list =
      "**Specs:**\n" <>
        Enum.map_join(specs, "\n", fn spec -> "- #{spec.name}" end)

    header <> status <> spec_list
  end

  defp determine_coverage_status(story, specs) do
    criteria_count = length(Map.get(story, :criteria, []))
    spec_count = length(specs)

    cond do
      criteria_count == 0 && spec_count > 0 ->
        "✓ **Status**: Covered (#{spec_count} specs)"

      criteria_count > 0 && spec_count >= criteria_count ->
        "✓ **Status**: Full coverage (#{spec_count}/#{criteria_count})"

      spec_count > 0 ->
        "⚠ **Status**: Partial coverage (#{spec_count}/#{criteria_count} criteria)"

      true ->
        "✗ **Status**: Missing coverage"
    end
  end

  defp format_stories_without_coverage(stories) do
    Enum.map_join(stories, "\n\n", fn story ->
      "## #{story.title}\n\n✗ **Status**: Missing coverage - No specs found"
    end)
  end

  defp format_criterion_coverage(criterion, []) do
    "- ✗ **Uncovered**: #{criterion.description}"
  end

  defp format_criterion_coverage(criterion, specs) do
    spec_names = Enum.map_join(specs, ", ", & &1.name)
    "- ✓ **Covered**: #{criterion.description} (Specs: #{spec_names})"
  end
end
