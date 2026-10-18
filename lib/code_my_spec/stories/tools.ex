defmodule CodeMySpec.Stories.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AgentTasks,
      CodeMySpec.Agents,
      CodeMySpec.Agents.RoleProfile,
      CodeMySpec.Components,
      CodeMySpec.EpicDispatch,
      CodeMySpec.Epics,
      CodeMySpec.Issues,
      CodeMySpec.Stories,
      CodeMySpec.Tags,
      CodeMySpec.Tools,
      CodeMySpec.WorkingCopies
    ]

  def all do
    [
      CodeMySpec.Stories.Tools.AddCriterion,
      CodeMySpec.Stories.Tools.AnalyzeStoryLinkage,
      CodeMySpec.Stories.Tools.AssignEpicToWorkingCopy,
      CodeMySpec.Stories.Tools.AssignStoryToEpic,
      CodeMySpec.Stories.Tools.AssignStoryToWorkingCopy,
      CodeMySpec.Stories.Tools.ClearStoryComponent,
      CodeMySpec.Stories.Tools.CreateEpic,
      CodeMySpec.Stories.Tools.CreateStory,
      CodeMySpec.Stories.Tools.GetCriterion,
      CodeMySpec.Stories.Tools.GetStory,
      CodeMySpec.Stories.Tools.LinkCriterionToRule,
      CodeMySpec.Stories.Tools.ListEpics,
      CodeMySpec.Stories.Tools.ListProjectTags,
      CodeMySpec.Stories.Tools.ListStories,
      CodeMySpec.Stories.Tools.ListStoryTitles,
      CodeMySpec.Stories.Tools.MoveCriterion,
      CodeMySpec.Stories.Tools.ProposeEpic,
      CodeMySpec.Stories.Tools.ReleaseStoryFromWorkingCopy,
      CodeMySpec.Stories.Tools.RestoreCriterion,
      CodeMySpec.Stories.Tools.RestoreStory,
      CodeMySpec.Stories.Tools.RetireCriterion,
      CodeMySpec.Stories.Tools.RetireStory,
      CodeMySpec.Stories.Tools.SetActiveStory,
      CodeMySpec.Stories.Tools.SetEpicStoriesReady,
      CodeMySpec.Stories.Tools.SetStoryComponent,
      CodeMySpec.Stories.Tools.StartStoryInterview,
      CodeMySpec.Stories.Tools.StartStoryReview,
      CodeMySpec.Stories.Tools.StartThreeAmigosSession,
      CodeMySpec.Stories.Tools.TagStories,
      CodeMySpec.Stories.Tools.TriageIssues,
      CodeMySpec.Stories.Tools.UnassignEpicFromWorkingCopy,
      CodeMySpec.Stories.Tools.UnassignStoryFromWorkingCopy,
      CodeMySpec.Stories.Tools.UpdateEpic,
      CodeMySpec.Stories.Tools.UpdateStory
    ]
  end
end
