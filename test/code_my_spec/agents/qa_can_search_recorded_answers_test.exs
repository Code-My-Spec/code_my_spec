defmodule CodeMySpec.Agents.QaCanSearchRecordedAnswersTest do
  @moduledoc """
  Issue `f8fa7f3c`. Main directed a QA task to read two recorded product
  answers before passing a criterion, and the agent could not: calling
  `search_answers` raised "search_answers is not a tool a qa agent carries"
  -- it was granted to product only, with no way for any other role to read
  a decision it was told to check against.

  John, 2026-10-19: give QA `search_answers`, read-only. It writes nothing,
  so this does not touch `holds_problems?` or any write grant qa still
  lacks.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.ToolSets

  test "qa may search recorded answers" do
    assert "search_answers" in ToolSets.for_role(:qa),
           "main directed QA to read a recorded decision before passing a criterion, " <>
             "and QA has no way to do that without this"
  end
end
