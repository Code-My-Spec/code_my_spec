defmodule CodeMySpec.Promotion.AMigrationThatRaisesInTheServerIsNamedTest do
  @moduledoc """
  A reload of the checkout this server runs from migrates inside the server.
  A migration that raises there must fail the landing by name, not leave the
  server unmigrated behind a landing that reads as clean.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.BootVersion
  alias CodeMySpec.Promotion

  @moduletag :tmp_dir

  test "the failure names the migration that raised", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "29990101000000_breaks.exs"), """
    defmodule CodeMySpec.Repo.Migrations.Breaks do
      use Ecto.Migration
      # The migration lock holds the sandbox's one connection while the
      # migration's own task waits for it.
      @disable_migration_lock true
      def change, do: raise("it broke")
    end
    """)

    assert {:error, %{reason: reason}} = Promotion.migrate_here(BootVersion.root(), dir)
    assert reason =~ "migration 29990101000000 breaks failed in the running server"
    assert reason =~ "it broke"
  end

  test "a checkout this server does not run from is not migrated here", %{tmp_dir: dir} do
    assert Promotion.migrate_here(dir, dir) == {:ok, []}
  end
end
