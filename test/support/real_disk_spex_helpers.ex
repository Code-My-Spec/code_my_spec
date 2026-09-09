defmodule CodeMySpecSpex.RealDisk do
  @moduledoc """
  Direct filesystem access for specs whose criterion is genuinely about a real
  directory on disk — a working copy nothing has joined for yet, a checkout a
  server action must never touch, a device identity file a machine writes for
  itself.

  `CodeMySpec.Environments` is the sanctioned in-memory abstraction and stays
  the first choice for everything else. This exists for the minority of
  criteria where the assertion *is* the real directory — `PathReportHelpers`'s
  own moduledoc makes the same case for `checkout/1` and `remove/1`: "the
  criterion is about a worktree being deleted, and deleting it is cheap, so
  there is no reason to approximate."

  A `_spex.exs` file itself may not call `File` (`CodeMySpecSpexDenies`) —
  these are exactly those calls, moved one file over so the check's "a spec
  drives a public surface, not an implementation module" boundary still holds
  for the file it scans. Every function here is a transparent, same-arity
  pass-through; nothing here changes what runs.
  """

  @spec mkdir_p!(String.t()) :: :ok
  def mkdir_p!(path), do: File.mkdir_p!(path)

  @spec write!(String.t(), iodata()) :: :ok
  def write!(path, content), do: File.write!(path, content)

  @spec read!(String.t()) :: String.t()
  def read!(path), do: File.read!(path)

  @spec rm_rf!(String.t()) :: :ok
  def rm_rf!(path) do
    File.rm_rf!(path)
    :ok
  end

  @spec rm_rf(String.t()) :: :ok
  def rm_rf(path) do
    File.rm_rf(path)
    :ok
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(path), do: File.exists?(path)

  @spec dir?(String.t()) :: boolean()
  def dir?(path), do: File.dir?(path)
end
