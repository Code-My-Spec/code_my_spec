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
      CodeMySpec.Requirements.SpecTestAlignmentChecker
    ]
end
