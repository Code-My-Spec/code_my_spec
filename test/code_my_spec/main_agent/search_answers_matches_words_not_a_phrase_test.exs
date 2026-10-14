defmodule CodeMySpec.Agents.Main.SearchAnswersMatchesWordsNotAPhraseTest do
  @moduledoc """
  `search_answers` takes words from the question being handled, and an agent
  passes several. It matched the whole query as one phrase, so a query of
  keywords found nothing: product searched "QA identity tap_out permission
  request deploy key account owner dev sign in", found no precedent, and
  escalated (2026-10-13).
  """

  use CodeMySpecSpex.Case, async: true

  import CodeMySpecSpex.QuestionRoutingHelpers

  alias CodeMySpec.Agents.Main, as: MainAgent

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "keywords from the question find the settled one", context do
    id = ask(context, "Should QA own a tap-out permission raised through the deploy key?")
    user_answers(context, id, "Let's have a product discussion about harness auth")

    results = MainAgent.search_answers(context.scope, "QA tap-out permission deploy key owner")

    assert Enum.any?(results, &(&1.id == id)),
           "search_answers matched the query as one phrase and missed a question holding its words"
  end

  test "the answer sharing the most words comes first", context do
    loose = ask(context, "Should the deploy key rotate monthly?")
    user_answers(context, loose, "Yes")
    close = ask(context, "Should QA own a tap-out permission raised through the deploy key?")
    user_answers(context, close, "Product discussion")

    assert [%{id: ^close} | _] =
             MainAgent.search_answers(context.scope, "QA tap-out permission deploy key")
  end

  test "a question sharing none of the words is not returned", context do
    id = ask(context, "Should the CLI migrate a local database?")
    user_answers(context, id, "Hard cutover")

    refute Enum.any?(
             MainAgent.search_answers(context.scope, "QA tap-out permission"),
             &(&1.id == id)
           )
  end
end
