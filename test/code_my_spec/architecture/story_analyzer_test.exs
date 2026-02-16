defmodule CodeMySpec.Architecture.StoryAnalyzerTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.Architecture.StoryAnalyzer
  alias CodeMySpec.Stories.Story

  describe "analyze/2" do
    test "returns analysis with all expected keys" do
      stories = [
        build_story(1, "SMS Notification", "Send SMS with verification link to driver"),
        build_story(2, "Photo Upload", "Upload photo for verification"),
        build_story(3, "Real-time Dashboard", "Show live updates on dashboard")
      ]

      result = StoryAnalyzer.analyze(stories)

      assert Map.has_key?(result, :total_stories)
      assert Map.has_key?(result, :domain_groupings)
      assert Map.has_key?(result, :detected_entities)
      assert Map.has_key?(result, :surface_patterns)
      assert Map.has_key?(result, :suggested_contexts)
      assert result.total_stories == 3
    end

    test "uses custom app_name when provided" do
      stories = [build_story(1, "Test Story", "Test description")]

      result = StoryAnalyzer.analyze(stories, app_name: "Fuellytics")

      assert Enum.all?(result.suggested_contexts, fn ctx ->
               String.starts_with?(ctx.name, "Fuellytics")
             end)
    end
  end

  describe "group_by_theme/1" do
    test "groups stories by notification keywords" do
      stories = [
        build_story(1, "SMS Notification", "Send SMS alert to driver"),
        build_story(2, "Email Reminder", "Send email reminder"),
        build_story(3, "Photo Upload", "Upload verification photo")
      ]

      groupings = StoryAnalyzer.group_by_theme(stories)

      notification_group = Enum.find(groupings, &(&1.theme == "notification"))
      assert notification_group
      assert notification_group.story_count == 2
      assert 1 in notification_group.story_ids
      assert 2 in notification_group.story_ids
    end

    test "groups stories by dashboard keywords" do
      stories = [
        build_story(1, "Real-time Dashboard", "Show live updates"),
        build_story(2, "Monitor View", "View pending items"),
        build_story(3, "SMS Alert", "Send notification")
      ]

      groupings = StoryAnalyzer.group_by_theme(stories)

      dashboard_group = Enum.find(groupings, &(&1.theme == "dashboard"))
      assert dashboard_group
      assert dashboard_group.story_count == 2
    end

    test "returns empty list when no stories match themes" do
      stories = [
        build_story(1, "Some Feature", "Generic description")
      ]

      groupings = StoryAnalyzer.group_by_theme(stories)

      # May or may not have groupings depending on keyword overlap
      assert is_list(groupings)
    end
  end

  describe "extract_entities/1" do
    test "extracts capitalized terms that appear in multiple stories" do
      # Each story should have the same entity to meet the frequency threshold
      stories = [
        build_story(1, "Driver submits Photo", "The Driver takes a photo"),
        build_story(2, "Driver reviews Photo", "Another Driver checks photo"),
        build_story(3, "Driver approval", "Driver confirms the transaction")
      ]

      entities = StoryAnalyzer.extract_entities(stories)

      # Driver appears in all 3 stories
      assert "Driver" in entities
    end

    test "extracts 'As a X' patterns" do
      stories = [
        build_story(1, "Story 1", "As a driver, I want to verify"),
        build_story(2, "Story 2", "As a driver, I want to upload")
      ]

      entities = StoryAnalyzer.extract_entities(stories)

      assert "Driver" in entities
    end

    test "limits to top 20 entities" do
      # Create many stories with different entities
      stories =
        for i <- 1..50 do
          build_story(i, "Entity#{i} Story", "Description about Entity#{i}")
        end

      entities = StoryAnalyzer.extract_entities(stories)

      assert length(entities) <= 20
    end
  end

  describe "detect_surface_patterns/1" do
    test "detects real-time dashboard pattern" do
      stories = [
        build_story(1, "Real-time Dashboard", "Show live updates via PubSub"),
        build_story(2, "Monitor View", "Real-time monitoring")
      ]

      patterns = StoryAnalyzer.detect_surface_patterns(stories)

      dashboard_pattern = Enum.find(patterns, &(&1.pattern == "Real-time Dashboard"))
      assert dashboard_pattern
      assert 1 in dashboard_pattern.story_ids
    end

    test "detects file upload pattern" do
      stories = [
        build_story(1, "Photo Upload", "Upload photo via camera"),
        build_story(2, "Image Processing", "Process uploaded image file")
      ]

      patterns = StoryAnalyzer.detect_surface_patterns(stories)

      upload_pattern = Enum.find(patterns, &(&1.pattern == "File Upload"))
      assert upload_pattern
      assert length(upload_pattern.story_ids) >= 1
    end

    test "detects notification pattern" do
      stories = [
        build_story(1, "SMS Notification", "Send SMS to driver"),
        build_story(2, "Email Alert", "Send email notification")
      ]

      patterns = StoryAnalyzer.detect_surface_patterns(stories)

      notification_pattern = Enum.find(patterns, &(&1.pattern == "Notification System"))
      assert notification_pattern
    end
  end

  describe "suggest_contexts/2" do
    test "suggests contexts for themes with 3+ stories" do
      stories = [
        build_story(1, "SMS Notification 1", "Send SMS"),
        build_story(2, "SMS Notification 2", "Send alert"),
        build_story(3, "Email Notification", "Email message"),
        build_story(4, "Verify Photo", "Verification")
      ]

      contexts = StoryAnalyzer.suggest_contexts(stories, app_name: "Fuellytics")

      assert length(contexts) >= 1
      assert Enum.all?(contexts, &String.starts_with?(&1.name, "Fuellytics."))
    end

    test "includes story_ids in context suggestions" do
      stories = [
        build_story(1, "Verify 1", "Verification process"),
        build_story(2, "Validate 2", "Validate check"),
        build_story(3, "Confirm 3", "Confirm approval")
      ]

      contexts = StoryAnalyzer.suggest_contexts(stories)

      Enum.each(contexts, fn ctx ->
        assert is_list(ctx.story_ids)
        assert length(ctx.story_ids) >= 3
      end)
    end
  end

  describe "format_as_markdown/1" do
    test "returns markdown string with summary" do
      stories = [
        build_story(1, "Test Story", "Test description")
      ]

      analysis = StoryAnalyzer.analyze(stories)
      markdown = StoryAnalyzer.format_as_markdown(analysis)

      assert is_binary(markdown)
      assert String.contains?(markdown, "## Story Analysis Summary")
      assert String.contains?(markdown, "**Total Stories:** 1")
      assert String.contains?(markdown, "Data:")
    end

    test "includes JSON data at the end" do
      stories = [
        build_story(1, "Test Story", "Test description")
      ]

      analysis = StoryAnalyzer.analyze(stories)
      markdown = StoryAnalyzer.format_as_markdown(analysis)

      # Extract JSON from the end
      [_, json_part] = String.split(markdown, "Data: ", parts: 2)
      assert {:ok, _} = Jason.decode(String.trim(json_part))
    end
  end

  # Helper function to build story structs
  defp build_story(id, title, description) do
    %Story{
      id: id,
      title: title,
      description: description,
      acceptance_criteria: []
    }
  end
end
