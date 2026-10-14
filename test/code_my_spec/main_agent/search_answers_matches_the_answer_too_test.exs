defmodule CodeMySpec.Agents.Main.SearchAnswersMatchesTheAnswerTooTest do
  @moduledoc """
  b6380ea4. A decision's subject matter sometimes lives only in how it was
  settled: a generically-phrased question answered in specific terms used to
  be unsearchable by those terms at all, because `search_answers` matched only
  the question's own text.
  """

  use CodeMySpecSpex.Case, async: true

  import CodeMySpecSpex.QuestionRoutingHelpers

  alias CodeMySpec.Agents.Main, as: MainAgent

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "a term that appears only in the answer still finds the settled question", context do
    id = ask(context, "Should we change how the CLI migrates a local database?")
    user_answers(context, id, "Hard cutover, no dual-write")

    results = MainAgent.search_answers(context.scope, "hard cutover")

    assert Enum.any?(results, &(&1.id == id)),
           "search_answers did not find a question whose only matching text is its answer"
  end
end
