defmodule CodeMySpec.MigrateTestPartitionsTest do
  @moduledoc """
  The task visits all three of a working copy's test databases.

  `MIX_ENV=test mix ecto.migrate` migrates one and says nothing about the other
  two, which is how a tree with a correct, committed, applied migration produced
  479 spex failures naming a column it had (`d86b09cd`).
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Cms.MigrateTestPartitions

  describe "partitions/1" do
    test "names the base and both analyzer partitions" do
      assert {:ok, names} = MigrateTestPartitions.partitions("code_my_spec_testh1a2b3c4d")

      assert names == [
               "code_my_spec_testh1a2b3c4d",
               "code_my_spec_testh1a2b3c4da",
               "code_my_spec_testh1a2b3c4ds"
             ]
    end

    test "the base comes first, so a failure stops before the partitions diverge" do
      assert {:ok, [base | _]} = MigrateTestPartitions.partitions("code_my_spec_testh1a2b3c4d")

      assert base == "code_my_spec_testh1a2b3c4d"
    end

    test "the primary checkout's bare name still yields three" do
      assert {:ok, names} = MigrateTestPartitions.partitions("code_my_spec_test")

      assert length(names) == 3
      assert "code_my_spec_tests" in names
    end

    # The guard the 2026-08-13 incident needed and did not have: a migrate that
    # could be aimed at `code_my_spec_dev` emptied the shared development
    # database three times. Nothing here can name one, and this is what keeps it
    # so.
    test "refuses a database that is not one of this repo's test databases" do
      assert {:error, message} = MigrateTestPartitions.partitions("code_my_spec_dev")

      assert message =~ "code_my_spec_dev"
      assert message =~ "not one of this repo's test databases"
    end

    test "refuses the production database by the same rule" do
      assert {:error, _} = MigrateTestPartitions.partitions("code_my_spec_prod")
    end
  end
end
