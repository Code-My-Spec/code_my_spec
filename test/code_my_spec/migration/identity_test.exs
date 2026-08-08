defmodule CodeMySpec.Migration.IdentityTest do
  @moduledoc """
  What a migrated story can still be called afterwards.

  Story ids are per-deployment sequences and the two ranges overlap, so a
  migration renumbers everything into numbers that are *also* valid on the
  source. After migrating this project, `727` named one story on the server and
  a different one on the harness; guided intake was `990` on one side and `875`
  on the other. Nothing errors — both sides answer confidently and disagree.

  So the source id travels and is recorded. These pin that it is written, that
  it is what a second run recognises its own rows by, and that recognition
  survives the two edits which used to break it: a retitled story upstream, and
  two stories sharing a title.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Migration
  alias CodeMySpec.Stories

  setup do
    scope = full_scope_fixture()

    # Straight through the changeset: `import_project/2` refuses without a paid
    # plan, and `Accounts.update_account/3` needs manage_account, which a plain
    # fixture scope does not carry.
    account = scope.active_account |> Ecto.Changeset.change(%{plan: :paid}) |> Repo.update!()

    {:ok, scope: %{scope | active_account: account}}
  end

  defp payload(stories), do: %{"stories" => stories}

  defp story(local_id, title),
    do: %{"local_id" => local_id, "title" => title, "story" => "as a user", "description" => "d"}

  test "a migrated story records the id it had on the source", %{scope: scope} do
    {:ok, _} = Migration.import_project(scope, payload([story(990, "Guided intake")]))

    {:ok, [migrated]} = Stories.list_project_stories(scope)

    assert migrated.migrated_from_id == 990,
           "without this there is no way to translate a reference — and the id it was " <>
             "given here is very likely a real story on the source, so asking either " <>
             "side by number returns a confident wrong answer"

    refute migrated.id == 990,
           "the destination assigns its own; that is the renumbering this exists to survive"
  end

  test "a second run recognises its own rows rather than duplicating them", %{scope: scope} do
    {:ok, _} = Migration.import_project(scope, payload([story(990, "Guided intake")]))
    {:ok, _} = Migration.import_project(scope, payload([story(990, "Guided intake")]))

    {:ok, stories} = Stories.list_project_stories(scope)
    assert length(stories) == 1
  end

  test "a story retitled upstream is still the same story", %{scope: scope} do
    {:ok, _} = Migration.import_project(scope, payload([story(990, "Guided intake")]))

    {:ok, _} =
      Migration.import_project(scope, payload([story(990, "Guided intake, renamed")]))

    {:ok, stories} = Stories.list_project_stories(scope)

    assert length(stories) == 1,
           "matching on title alone made a retitled story a second story, so a project " <>
             "grew a duplicate every time somebody reworded a title upstream"
  end

  test "a duplicate title is refused by the destination, not silently merged", %{scope: scope} do
    {:ok, _} = Migration.import_project(scope, payload([story(101, "Same words")]))

    # `stories_title_project_id_index` makes titles unique per project here, so
    # the collapse this was written to guard against cannot happen — a second
    # story with one title fails the insert and rolls the whole import back.
    # Recorded rather than deleted: it is the reason title-matching was safe as
    # a fallback, and the reason it is only a fallback.
    assert {:error, _} =
             Migration.import_project(scope, payload([story(102, "Same words")]))

    {:ok, stories} = Stories.list_project_stories(scope)
    assert Enum.map(stories, & &1.migrated_from_id) == [101]
  end
end
