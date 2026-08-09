defmodule CodeMySpec.Migration.DuplicateTitleTest do
  @moduledoc """
  Two stories in one payload that would land on the same title.

  `put_stories/3` indexes the destination once, before the loop, and never
  updates it — so a title this run has already inserted is invisible to every
  later story. The second one inserted again and died on
  `stories_title_project_id_index`: a 500 from `POST /api/migrations` importing
  98 stories into an *empty* project, naming neither the title nor either
  source story.

  The two collisions want opposite handling, which is why this is not simply
  "skip duplicates":

    - the same source story listed twice is a duplicate entry, and the row
      already created for it is the right answer
    - two different source stories sharing a title cannot both exist under a
      unique index, and choosing between them is Sam's decision, not the
      importer's. Adopting one for the other is the silent merge that
      `match_by_title` already refuses.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Migration
  alias CodeMySpec.Repo

  setup do
    scope = full_scope_fixture()

    # `import_project/2` refuses without a paid plan, and updating the account
    # through the context needs manage_account, which a fixture scope lacks.
    account = scope.active_account |> Ecto.Changeset.change(%{plan: :paid}) |> Repo.update!()

    {:ok, scope: %{scope | active_account: account}}
  end

  defp payload(stories), do: %{"stories" => stories}

  defp story(local_id, title),
    do: %{"local_id" => local_id, "title" => title, "story" => "as a user", "description" => "d"}

  test "the same source story listed twice imports once", %{scope: scope} do
    assert {:ok, summary} =
             Migration.import_project(scope, payload([story(1, "A thing"), story(1, "A thing")]))

    assert summary["stories"] == 1 or summary[:stories] == 1
  end

  test "two source stories sharing a title are refused, naming both", %{scope: scope} do
    assert {:error, {:duplicate_title, "A thing", first, second}} =
             Migration.import_project(scope, payload([story(1, "A thing"), story(2, "A thing")]))

    assert first == 1
    assert second == 2
  end

  test "distinct titles import cleanly", %{scope: scope} do
    assert {:ok, _} =
             Migration.import_project(scope, payload([story(1, "One"), story(2, "Two")]))
  end
end
