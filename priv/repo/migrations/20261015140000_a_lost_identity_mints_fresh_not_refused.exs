defmodule CodeMySpec.Repo.Migrations.ALostIdentityMintsFreshNotRefused do
  @moduledoc """
  Reverses `working_copies_project_device_root_index` (20260825120000).

  That index backstopped `recognise_or_create/3`'s device+root lookup so a
  regression there would refuse a second row rather than let it quietly
  duplicate. Story 1000's criterion 5 settled the lookup itself the other
  way: a join with no id is always a new agent, even from a path and device
  the server has seen, because the alternative merges two different agents
  that share one. With the lookup gone, this index no longer backstops it --
  it blocks it. A lost-identity rejoin now mints, and the second row's own
  `report_root` must succeed rather than collide with the first's.

  The rows this reintroduces are not reconciled here -- reclaiming a
  checkout's quiet duplicates is its own piece of work. See 45c044d1.
  """
  use Ecto.Migration

  def change do
    drop unique_index(
           :working_copies,
           [:project_id, :device_id, :root],
           name: :working_copies_project_device_root_index
         )
  end
end
