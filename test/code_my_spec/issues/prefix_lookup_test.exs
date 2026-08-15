defmodule CodeMySpec.Issues.PrefixLookupTest do
  @moduledoc """
  An issue id can be given as the prefix everyone actually writes.

  `98fa6656`. `get_issue/2` took only a full UUID and answered anything else with
  `nil`, which every caller renders as "Issue not found." — a claim about the
  issue where the truth was a claim about the argument.

  Nothing in this codebase cites a full UUID. Commit messages, code comments,
  spec files and issue bodies all use the 8-character prefix, because that is
  what fits in prose. So the common path here is copying a prefix out of a
  comment, and that path always failed.

  What it cost: a correct citation was deleted from `justfile` on the strength of
  a "not found" for `f58acb37`, which exists and was the right reference. The
  repair — removing the citation — looks like diligence, which is what makes it
  worse than an error, and it was caught only because an unrelated listing
  happened to print the issue later.

  `{:ambiguous, ids}` is a separate answer on purpose. Folding it into
  `:not_found` would rebuild the original defect one case along.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Issues

  setup do
    scope = full_scope_fixture()

    {:ok, issue} =
      Issues.create_issue(scope, %{
        title: "A findable issue",
        description: "body",
        severity: :medium
      })

    %{scope: scope, issue: issue}
  end

  describe "fetch_issue/2" do
    test "finds by full id", %{scope: scope, issue: issue} do
      assert {:ok, found} = Issues.fetch_issue(scope, issue.id)
      assert found.id == issue.id
    end

    test "finds by the 8-character prefix every reference uses", %{scope: scope, issue: issue} do
      prefix = String.slice(issue.id, 0, 8)

      assert {:ok, found} = Issues.fetch_issue(scope, prefix)
      assert found.id == issue.id
    end

    test "is case-insensitive, since prefixes get typed by hand", %{scope: scope, issue: issue} do
      prefix = issue.id |> String.slice(0, 8) |> String.upcase()

      assert {:ok, found} = Issues.fetch_issue(scope, prefix)
      assert found.id == issue.id
    end

    test "a prefix matching nothing is not found", %{scope: scope} do
      assert Issues.fetch_issue(scope, "ffffffff") == :not_found
    end

    test "a non-hex argument is not found rather than a query", %{scope: scope} do
      assert Issues.fetch_issue(scope, "not-an-id-at-all-zz") == :not_found
    end

    # Below four characters is not a prefix anyone typed on purpose, and
    # matching it would turn a typo into a wrong issue — the one outcome worse
    # than the message this fixes.
    test "a very short prefix is refused rather than resolved", %{scope: scope, issue: issue} do
      assert Issues.fetch_issue(scope, String.slice(issue.id, 0, 2)) == :not_found
    end

    test "an ambiguous prefix says so, and names the candidates", %{scope: scope, issue: issue} do
      # Both issues share the project; the shared prefix is what makes them
      # indistinguishable, so it is constructed rather than hoped for.
      shared = String.slice(issue.id, 0, 4)

      other = insert_issue_with_id_prefix(scope, shared)

      assert {:ambiguous, ids} = Issues.fetch_issue(scope, shared)
      assert issue.id in ids
      assert other in ids
    end

    test "another project's issue is not reachable by prefix", %{issue: issue} do
      elsewhere = full_scope_fixture()

      assert Issues.fetch_issue(elsewhere, String.slice(issue.id, 0, 8)) == :not_found
    end
  end

  describe "get_issue/2" do
    test "accepts a prefix too, so the mutating tools do", %{scope: scope, issue: issue} do
      found = Issues.get_issue(scope, String.slice(issue.id, 0, 8))

      assert found.id == issue.id
    end

    test "still answers nil when there is no single match", %{scope: scope} do
      assert Issues.get_issue(scope, "ffffffff") == nil
    end
  end

  # A second issue whose id begins with the same four characters.
  #
  # Inserted as a struct rather than through `create_issue/2`: that changeset
  # does not cast `:id`, so passing one is silently ignored and the database
  # assigns a fresh uuid — which produced a test that asserted ambiguity and
  # measured a single match.
  defp insert_issue_with_id_prefix(scope, prefix) do
    id = prefix <> String.slice(Ecto.UUID.generate(), 4, 32)

    Repo.insert!(%CodeMySpec.Issues.Issue{
      id: id,
      title: "A colliding issue",
      description: "body",
      severity: :low,
      status: :incoming,
      source: "qa_agent",
      project_id: scope.active_project.id,
      account_id: scope.active_account.id
    })

    id
  end
end
