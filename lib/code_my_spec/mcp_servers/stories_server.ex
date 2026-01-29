defmodule CodeMySpec.McpServers.StoriesServer do
  use Hermes.Server,
    name: "stories-server",
    version: "1.0.0",
    capabilities: [:tools]

  # Tool components
  component(CodeMySpec.McpServers.Stories.Tools.CreateStory)
  # component(CodeMySpec.McpServers.Stories.Tools.CreateStories)
  component(CodeMySpec.McpServers.Stories.Tools.UpdateStory)
  component(CodeMySpec.McpServers.Stories.Tools.DeleteStory)
  component(CodeMySpec.McpServers.Stories.Tools.GetStory)
  component(CodeMySpec.McpServers.Stories.Tools.ListStories)
  component(CodeMySpec.McpServers.Stories.Tools.ListStoryTitles)

  # Criterion tools
  component(CodeMySpec.McpServers.Stories.Tools.AddCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.UpdateCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.DeleteCriterion)

  # Tagging tools
  component(CodeMySpec.McpServers.Stories.Tools.ListProjectTags)
  component(CodeMySpec.McpServers.Stories.Tools.TagStories)

  # Session tools
  component(CodeMySpec.McpServers.Stories.Tools.StartStorySession)
end
