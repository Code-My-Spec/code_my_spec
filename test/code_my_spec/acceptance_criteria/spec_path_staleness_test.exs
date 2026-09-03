defmodule CodeMySpec.AcceptanceCriteria.SpecPathStalenessTest do
  @moduledoc """
  Whether a criterion's spex file has gone is a question about the checkout the
  manifest came from, not about whatever disk the server is sitting on.

  `stale?/1` was `not File.exists?(path)`, and `spec_path` is project-relative,
  so it resolved against the server's own cwd — the main checkout. A manifest
  from any other working copy was judged against a checkout it has nothing to do
  with. For a worktree whose spec files were uncommitted, every criterion read
  stale, was repointed at the same relative path, and read stale again on the
  next manifest — a repair that could not stick, because nothing it wrote could
  make `File.exists?` true somewhere else. `bdd_specs_exist` never satisfied.

  Found by devops-q-ec, who could not make it stick by restarting the harness or
  using fresh task ids — correctly, since the record was never what was wrong.
  Issue `5b538c8b`.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories

  # A path that is certainly not in the server's checkout, which is the whole
  # point: under the old check this alone decided the answer.
  @spec_path "test/spex/9999_a_story_from_another_worktree/criterion_4242_something_spex.exs"

  defp criterion_with_path(scope, path) do
    {:ok, story} =
      Stories.create_story(scope, %{title: "A story", description: "d", status: :in_progress})

    {:ok, criterion} =
      %Criterion{}
      |> Criterion.changeset(%{
        story_id: story.id,
        project_id: scope.active_project_id,
        description: "something",
        spec_path: path
      })
      |> Repo.insert()

    criterion
  end

  test "a path this checkout has is not treated as gone" do
    scope = full_scope_fixture()
    criterion = criterion_with_path(scope, @spec_path)

    # The manifest reports the file — the harness has just seen it on that
    # checkout's disk, which is the only evidence that matters.
    {:ok, repaired} =
      AcceptanceCriteria.claim_spec_paths(scope, %{criterion.id => @spec_path})

    assert repaired == 0, """
    A criterion whose recorded path is exactly what the manifest reported was
    repaired anyway. That is the loop: the row was already right, so the repair
    rewrites it to the same value and fires again on the next manifest.
    """

    assert Repo.get!(Criterion, criterion.id).spec_path == @spec_path
  end

  test "a path that has genuinely moved is still repaired, once" do
    scope = full_scope_fixture()
    old_path = "test/spex/9999_a_story/criterion_4242_old_wording_spex.exs"
    new_path = "test/spex/9999_a_story/criterion_4242_new_wording_spex.exs"

    criterion = criterion_with_path(scope, old_path)

    {:ok, repaired} = AcceptanceCriteria.claim_spec_paths(scope, %{criterion.id => new_path})

    assert repaired == 1, "a renamed spex must still be re-pointed — that is what the repair is for"
    assert Repo.get!(Criterion, criterion.id).spec_path == new_path

    # And it settles: the second manifest reports the same file and changes
    # nothing. This is the half that was broken.
    {:ok, again} = AcceptanceCriteria.claim_spec_paths(scope, %{criterion.id => new_path})

    assert again == 0, """
    The repair fired twice for one move. It has to converge, or every sync
    rewrites the same rows forever and `bdd_specs_exist` never settles.
    """
  end

  test "a criterion with no recorded path is claimed" do
    scope = full_scope_fixture()
    criterion = criterion_with_path(scope, nil)

    {:ok, repaired} = AcceptanceCriteria.claim_spec_paths(scope, %{criterion.id => @spec_path})

    assert repaired == 1, "an unclaimed criterion must still take the path it was found at"
    assert Repo.get!(Criterion, criterion.id).spec_path == @spec_path
  end
end
