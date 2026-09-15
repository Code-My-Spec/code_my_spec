defmodule CodeMySpec.Documents.FrameworkScopeTest do
  @moduledoc """
  A QA result may record a framework-scoped issue.

  `9198be0f` (2026-05-14) added `:framework` to `Issue`, `Issues`,
  `create_issue` and `list_issues`, plus four spex. It did not add it to the two
  document-side lists — `Documents.@valid_scopes` and `QaIssue.@scopes` — and
  nothing linked them, so the domain has been split for three months.

  The split is invisible from either side. `Issues.parse_scope/1` has a
  `"framework"` clause, so the code that *files* the issue was written expecting
  this to work; the code that validates the document it arrives in rejects it
  first, and the clause is unreachable from that path.

  What it costs: a QA agent that finds framework friction — the harness itself,
  a looping hook, a broken tool — and records it in its result document has the
  whole document rejected as invalid. Framework friction is exactly what a QA
  agent is most likely to hit and least able to route anywhere else.

  Found by sweeping `lib/` for enumerations of one domain that disagree, after
  the same shape turned up seven times in one session.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Documents.QaIssue

  @scopes_in_the_domain ~w(app qa docs framework)

  test "every scope the Issue schema accepts is accepted on a QA issue" do
    for scope <- @scopes_in_the_domain do
      changeset =
        QaIssue.changeset(%QaIssue{}, %{
          title: "something",
          severity: "high",
          description: "d",
          scope: scope
        })

      assert changeset.valid?, """
      `QaIssue` rejects scope #{inspect(scope)}, which `Issue` accepts.

      The document is the way a QA agent reports what it found, so a scope the
      domain has and the document does not is a finding with nowhere to go.
      """
    end
  end

  test "and it is fileable, not merely valid" do
    # `Issues.create_from_qa_result/3` filters on `Issues.fileable?/1` before
    # it ever reaches `parse_scope/1`, so validity alone does not mean the
    # issue lands. `fileable?/1` moved to `Issues` (formerly a boundary
    # cycle) but still takes anything shaped like a QaIssue, so this keeps
    # testing the real cross-domain question: a QaIssue this module
    # considers valid must also be one Issues will actually file.
    issue = %QaIssue{title: "t", severity: "high", scope: "framework"}

    assert CodeMySpec.Issues.fileable?(issue),
           "a valid framework issue that is not fileable is dropped silently, " <>
             "which is worse than the rejection it replaced"
  end

  test "the Issue schema is the authority these are measured against" do
    # If this fails, the domain moved and the lists above need re-reading rather
    # than the assertion being relaxed.
    schema_scopes =
      CodeMySpec.Issues.Issue
      |> Ecto.Enum.values(:scope)
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    assert schema_scopes == Enum.sort(@scopes_in_the_domain)
  end
end
