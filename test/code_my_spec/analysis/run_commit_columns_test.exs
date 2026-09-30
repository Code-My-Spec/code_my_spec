defmodule CodeMySpec.Analysis.RunCommitColumnsTest do
  @moduledoc """
  `analysis_runs` records the commit a run started on, whether the tree was
  clean then, and the commit it finished on. Nullable with no default: a run
  nobody reported a commit for has none.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Repo

  test "the three columns exist, nullable, with no default" do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_name = 'analysis_runs'
        AND column_name IN ('start_commit', 'start_tree_dirty', 'completed_commit')
      ORDER BY column_name
      """)

    assert rows == [
             ["completed_commit", "character varying", "YES", nil],
             ["start_commit", "character varying", "YES", nil],
             ["start_tree_dirty", "boolean", "YES", nil]
           ]
  end
end
