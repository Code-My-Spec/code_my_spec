defmodule CodeMySpec.Requirements.CheckerType do
  @moduledoc false

  use CodeMySpec.Utils.ModuleType,
    valid_types: [
      CodeMySpec.Requirements.FileExistenceChecker,
      CodeMySpec.Requirements.DocumentValidityChecker,
      CodeMySpec.Requirements.TestStatusChecker,
      CodeMySpec.Requirements.DependencyChecker,
      CodeMySpec.Requirements.HierarchicalChecker,
      CodeMySpec.Requirements.ContextReviewFileChecker,
      CodeMySpec.Requirements.ContextReviewValidityChecker,
      CodeMySpec.Requirements.SpecTestAlignmentChecker,
      CodeMySpec.Requirements.ComponentLinkedChecker,
      CodeMySpec.Requirements.BddSpecExistenceChecker,
      CodeMySpec.Requirements.BddSpecPassingChecker,
      CodeMySpec.Requirements.StoryQaChecker,
      CodeMySpec.Requirements.ArtifactExistenceChecker,
      CodeMySpec.Requirements.AllStoriesCompleteChecker,
      CodeMySpec.Requirements.ComponentCompleteChecker,
      CodeMySpec.Requirements.ProjectQaChecker
    ]
end
