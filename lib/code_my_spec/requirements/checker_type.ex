defmodule CodeMySpec.Requirements.CheckerType do
  @moduledoc false

  use CodeMySpec.Utils.ModuleType,
    valid_types: [
      CodeMySpec.Requirements.AcceptedIssuesChecker,
      CodeMySpec.Requirements.AllBddSpecsPassingChecker,
      CodeMySpec.Requirements.AllStoriesCompleteChecker,
      CodeMySpec.Requirements.ArtifactExistenceChecker,
      CodeMySpec.Requirements.BddSpecExistenceChecker,
      CodeMySpec.Requirements.BddSpecPassingChecker,
      CodeMySpec.Requirements.ComponentCompleteChecker,
      CodeMySpec.Requirements.ComponentLinkedChecker,
      CodeMySpec.Requirements.ContextReviewFileChecker,
      CodeMySpec.Requirements.ContextReviewValidityChecker,
      CodeMySpec.Requirements.DependencyChecker,
      CodeMySpec.Requirements.DocumentValidityChecker,
      CodeMySpec.Requirements.FileExistenceChecker,
      CodeMySpec.Requirements.HierarchicalChecker,
      CodeMySpec.Requirements.IncomingIssuesChecker,
      CodeMySpec.Requirements.ProjectQaChecker,
      CodeMySpec.Requirements.ProjectSetupChecker,
      CodeMySpec.Requirements.QaIntegrationPlanChecker,
      CodeMySpec.Requirements.QaJourneyExecuteChecker,
      CodeMySpec.Requirements.QaJourneyPlanChecker,
      CodeMySpec.Requirements.QaJourneyWallabyChecker,
      CodeMySpec.Requirements.QaPreflightChecker,
      CodeMySpec.Requirements.SpecTestAlignmentChecker,
      CodeMySpec.Requirements.StoryQaChecker,
      CodeMySpec.Requirements.TestStatusChecker
    ]
end
