defmodule CodeMySpec.BddRules.Tools do
  @moduledoc """
  The BDD tools an agent calls (rules, scenarios, questions), for
  `CodeMySpec.ToolLibrary`. Its own boundary: the tools also read Questions and
  Files, which the BddRules core does not depend on.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.BddRules,
      CodeMySpec.Files,
      CodeMySpec.Questions,
      CodeMySpec.Stories,
      CodeMySpec.Tools
    ]

  def all do
    [
      CodeMySpec.BddRules.Tools.AddQuestion,
      CodeMySpec.BddRules.Tools.AddRule,
      CodeMySpec.BddRules.Tools.AddScenario,
      CodeMySpec.BddRules.Tools.DeleteRule,
      CodeMySpec.BddRules.Tools.GetStoryGherkin,
      CodeMySpec.BddRules.Tools.ListQuestions,
      CodeMySpec.BddRules.Tools.ListRules,
      CodeMySpec.BddRules.Tools.ResolveQuestion,
      CodeMySpec.BddRules.Tools.UpdateRule,
      CodeMySpec.BddRules.Tools.UpdateScenario
    ]
  end
end
