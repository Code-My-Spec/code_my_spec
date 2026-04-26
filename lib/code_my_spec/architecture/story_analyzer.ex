defmodule CodeMySpec.Architecture.StoryAnalyzer do
  @moduledoc """
  Analyzes user stories to extract domain patterns, entities, and suggest bounded contexts.

  Used primarily for greenfield projects where no components exist yet.
  Provides insights to guide initial architecture design.
  """

  alias CodeMySpec.Stories.Story

  @type analysis_result :: %{
          total_stories: non_neg_integer(),
          domain_groupings: [domain_grouping()],
          detected_entities: [String.t()],
          surface_patterns: [surface_pattern()],
          suggested_contexts: [context_suggestion()]
        }

  @type domain_grouping :: %{
          theme: String.t(),
          keywords: [String.t()],
          story_ids: [integer()],
          story_count: non_neg_integer()
        }

  @type surface_pattern :: %{
          pattern: String.t(),
          description: String.t(),
          story_ids: [integer()],
          suggestion: String.t()
        }

  @type context_suggestion :: %{
          name: String.t(),
          description: String.t(),
          entities: [String.t()],
          story_ids: [integer()]
        }

  @domain_keywords %{
    "verification" =>
      ~w(verify verification validate check confirm approve photo camera image upload ocr),
    "notification" => ~w(sms email alert notify notification message send reminder),
    "authentication" => ~w(login auth authenticate token session user password sign),
    "dashboard" => ~w(dashboard panel view list monitor display real-time realtime),
    "reporting" => ~w(report summary analytics export audit trail log history),
    "configuration" => ~w(config configure setting rule threshold admin manage),
    "integration" => ~w(integration webhook api external sync import processor),
    "storage" => ~w(store storage save persist upload download file image photo),
    "driver" => ~w(driver operator user onboard assign vehicle fleet),
    "vehicle" => ~w(vehicle car truck odometer fuel mileage sticker qr),
    "transaction" => ~w(transaction purchase swipe card payment amount),
    "fraud" => ~w(fraud flag suspicious anomaly lock unlock block detection)
  }

  @surface_patterns [
    %{
      keywords: ~w(real-time realtime dashboard monitor live update),
      pattern: "Real-time Dashboard",
      suggestion: "LiveView with PubSub"
    },
    %{
      keywords: ~w(api webhook integration external endpoint),
      pattern: "External API Integration",
      suggestion: "Controller with API authentication"
    },
    %{
      keywords: ~w(sms email notification alert send message),
      pattern: "Notification System",
      suggestion: "GenServer or Oban job with external service integration"
    },
    %{
      keywords: ~w(upload photo image camera file),
      pattern: "File Upload",
      suggestion: "LiveView with upload component and storage adapter"
    },
    %{
      keywords: ~w(report export summary analytics pdf csv),
      pattern: "Reporting",
      suggestion: "Background job with PDF/CSV generation"
    },
    %{
      keywords: ~w(config configure setting rule threshold),
      pattern: "Configuration Management",
      suggestion: "LiveView CRUD with runtime config loading"
    },
    %{
      keywords: ~w(pwa mobile app camera offline),
      pattern: "PWA/Mobile Interface",
      suggestion: "Minimal controller endpoint serving PWA shell"
    }
  ]

  @doc """
  Performs comprehensive analysis on a list of stories.

  Returns grouped themes, detected entities, surface patterns, and context suggestions.
  """
  @spec analyze([Story.t()], keyword()) :: analysis_result()
  def analyze(stories, opts \\ []) do
    %{
      total_stories: length(stories),
      domain_groupings: group_by_theme(stories),
      detected_entities: extract_entities(stories),
      surface_patterns: detect_surface_patterns(stories),
      suggested_contexts: suggest_contexts(stories, opts)
    }
  end

  @doc """
  Groups stories by domain/theme based on keyword analysis.
  """
  @spec group_by_theme([Story.t()]) :: [domain_grouping()]
  def group_by_theme(stories) do
    @domain_keywords
    |> Enum.map(fn {theme, keywords} ->
      matching = find_matching_stories(stories, keywords)

      %{
        theme: theme,
        keywords: keywords,
        story_ids: Enum.map(matching, & &1.id),
        story_count: length(matching)
      }
    end)
    |> Enum.filter(&(&1.story_count > 0))
    |> Enum.sort_by(& &1.story_count, :desc)
  end

  @doc """
  Extracts potential entities from story text using pattern matching.
  """
  @spec extract_entities([Story.t()]) :: [String.t()]
  def extract_entities(stories) do
    stories
    |> Enum.flat_map(&extract_story_entities/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_entity, count} -> count >= 2 end)
    |> Enum.sort_by(fn {_entity, count} -> count end, :desc)
    |> Enum.map(fn {entity, _count} -> entity end)
    |> Enum.take(20)
  end

  @doc """
  Detects surface-level patterns suggesting specific component types.
  """
  @spec detect_surface_patterns([Story.t()]) :: [surface_pattern()]
  def detect_surface_patterns(stories) do
    @surface_patterns
    |> Enum.map(fn pattern_def ->
      matching = find_matching_stories(stories, pattern_def.keywords)

      %{
        pattern: pattern_def.pattern,
        description: pattern_def.suggestion,
        story_ids: Enum.map(matching, & &1.id),
        suggestion: pattern_def.suggestion
      }
    end)
    |> Enum.filter(&(&1.story_ids != []))
    |> Enum.sort_by(&length(&1.story_ids), :desc)
  end

  @doc """
  Suggests bounded contexts based on story groupings and entity analysis.
  """
  @spec suggest_contexts([Story.t()], keyword()) :: [context_suggestion()]
  def suggest_contexts(stories, opts \\ []) do
    app_name = Keyword.get(opts, :app_name, "App")
    groupings = group_by_theme(stories)
    entities = extract_entities(stories)

    groupings
    |> Enum.filter(&(&1.story_count >= 3))
    |> Enum.map(fn grouping ->
      context_name = build_context_name(app_name, grouping.theme)
      context_entities = find_related_entities(grouping, entities, stories)

      %{
        name: context_name,
        description: build_context_description(grouping.theme),
        entities: context_entities,
        story_ids: grouping.story_ids
      }
    end)
  end

  @doc """
  Formats analysis results as a markdown summary with embedded JSON.
  """
  @spec format_as_markdown(analysis_result()) :: String.t()
  def format_as_markdown(analysis) do
    """
    ## Story Analysis Summary

    **Total Stories:** #{analysis.total_stories}
    **Suggested Contexts:** #{length(analysis.suggested_contexts)}
    **Detected Entities:** #{length(analysis.detected_entities)}

    ### Domain Groupings

    #{format_domain_groupings(analysis.domain_groupings)}

    ### Suggested Bounded Contexts

    #{format_context_suggestions(analysis.suggested_contexts)}

    ### Surface Component Patterns

    #{format_surface_patterns(analysis.surface_patterns)}

    ### Detected Entities

    #{format_entities(analysis.detected_entities)}
    """
  end

  # Private functions

  defp find_matching_stories(stories, keywords) do
    keyword_set = MapSet.new(keywords)

    Enum.filter(stories, fn story ->
      text = build_story_text(story)
      words = extract_words(text)

      Enum.any?(words, &MapSet.member?(keyword_set, &1))
    end)
  end

  defp build_story_text(story) do
    [
      story.title || "",
      story.description || "",
      criteria_text(story)
    ]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp extract_words(text) do
    text
    |> String.replace(~r/[^\w\s-]/, " ")
    |> String.split(~r/\s+/)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_story_entities(story) do
    text = "#{story.title} #{story.description}"

    # Extract capitalized terms (potential entity names)
    capitalized =
      Regex.scan(~r/\b([A-Z][a-z]+(?:\s[A-Z][a-z]+)?)\b/, text)
      |> Enum.map(&List.first/1)
      |> Enum.reject(&common_word?/1)

    # Extract "As a X" patterns
    actors =
      Regex.scan(~r/\bAs a\s+([a-z]+(?:\s[a-z]+)?)\b/i, text)
      |> Enum.map(fn [_, actor] -> String.capitalize(actor) end)

    capitalized ++ actors
  end

  defp common_word?(word) do
    common_words = ~w(I The A An In On At To For Of And Or But If Then When As So)
    word in common_words
  end

  defp build_context_name(app_name, theme) do
    module_part =
      theme
      |> String.split("_")
      |> Enum.map_join("", &String.capitalize/1)

    "#{app_name}.#{module_part}"
  end

  defp build_context_description("verification"), do: "Handles verification workflows and photo validation"
  defp build_context_description("notification"), do: "Manages SMS, email, and push notifications"
  defp build_context_description("authentication"), do: "User authentication and session management"
  defp build_context_description("dashboard"), do: "Real-time dashboard and monitoring interfaces"
  defp build_context_description("reporting"), do: "Analytics, reports, and audit trail exports"
  defp build_context_description("configuration"), do: "System configuration and rules management"
  defp build_context_description("integration"), do: "External service integrations and webhooks"
  defp build_context_description("storage"), do: "File storage and retrieval"
  defp build_context_description("driver"), do: "Driver management and onboarding"
  defp build_context_description("vehicle"), do: "Vehicle tracking and management"
  defp build_context_description("transaction"), do: "Transaction processing and tracking"
  defp build_context_description("fraud"), do: "Fraud detection and prevention"
  defp build_context_description(theme), do: "#{String.capitalize(theme)} domain"

  defp find_related_entities(grouping, all_entities, stories) do
    grouping_stories =
      stories
      |> Enum.filter(&(&1.id in grouping.story_ids))

    grouping_text =
      grouping_stories
      |> Enum.map_join(" ", &"#{&1.title} #{&1.description}")
      |> String.downcase()

    all_entities
    |> Enum.filter(fn entity ->
      String.contains?(grouping_text, String.downcase(entity))
    end)
    |> Enum.take(5)
  end

  defp format_domain_groupings(groupings) do
    Enum.map_join(groupings, "\n\n", fn g ->
      "**#{String.capitalize(g.theme)}** (#{g.story_count} stories)\n- Story IDs: #{Enum.join(g.story_ids, ", ")}"
    end)
  end

  defp format_context_suggestions(contexts) do
    contexts
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {ctx, idx} ->
      entities_str =
        if ctx.entities == [], do: "None detected", else: Enum.join(ctx.entities, ", ")

      story_ids_str = Enum.join(ctx.story_ids, ", ")

      """
      #{idx}. **#{ctx.name}** - #{ctx.description}
         - Entities: #{entities_str}
         - Stories: #{story_ids_str}
      """
    end)
  end

  defp format_surface_patterns(patterns) do
    Enum.map_join(patterns, "\n\n", fn p ->
      story_ids = Enum.join(p.story_ids, ", ")
      "- **#{p.pattern}** (Stories: #{story_ids})\n  → Suggest: #{p.suggestion}"
    end)
  end

  defp format_entities(entities) do
    if entities == [] do
      "No entities detected with significant frequency."
    else
      Enum.map_join(entities, "\n", &"- #{&1}")
    end
  end

  defp criteria_text(story) do
    case story.criteria do
      criteria when is_list(criteria) and criteria != [] ->
        Enum.map_join(criteria, " ", & &1.description)

      _ ->
        Enum.join(story.acceptance_criteria || [], " ")
    end
  end
end
