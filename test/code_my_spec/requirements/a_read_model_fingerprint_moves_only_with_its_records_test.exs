defmodule CodeMySpec.Requirements.AReadModelFingerprintMovesOnlyWithItsRecordsTest do
  @moduledoc """
  The read model's fingerprint names the records a harness was handed, so a
  report is served only while it is current. It must not move when nothing
  did: the database returns rows in no fixed order, and an update moves a
  row's place. Measured on a dev clone, every live copy's report read as
  stale for exactly this reason.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.CopyOverlay
  alias CodeMySpec.Stories.Story

  test "rows moving in the table leave the fingerprint where it was" do
    scope = full_scope_fixture()
    first = story_fixture(scope)
    story_fixture(scope)
    story_fixture(scope)

    {before, _payload} = CopyOverlay.served_read_model(scope)

    # Rewritten in place: same records, another physical order.
    Repo.update_all(from(s in Story, where: s.id == ^first.id),
      set: [updated_at: DateTime.utc_now()]
    )

    {later, _payload} = CopyOverlay.served_read_model(scope)

    assert later.fingerprint == before.fingerprint
  end
end
