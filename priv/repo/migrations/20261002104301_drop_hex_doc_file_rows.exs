defmodule CodeMySpec.Repo.Migrations.DropHexDocFileRows do
  @moduledoc """
  `hex_doc` stops being a file role (577de9bb step 6): hex docs are embedded
  server-side from hex.pm tarballs, not projected into
  `.code_my_spec/hex_docs/`. `Files.File` no longer lists the role, so a
  remaining row would fail to load. Rows are a projection of disk; nothing
  is lost.
  """

  use Ecto.Migration

  def up do
    execute("DELETE FROM files WHERE role = 'hex_doc'")
  end

  def down, do: :ok
end
