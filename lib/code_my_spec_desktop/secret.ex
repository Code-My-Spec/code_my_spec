defmodule CodeMySpecDesktop.Secret do
  @moduledoc """
  The desktop install's `secret_key_base`: generated on first boot, kept in
  the harness's state dir (`~/.codemyspec`, or beside `CMS_PROJECT_DIR`), and
  read by runtime.exs on every boot after.
  """

  def read_or_create!(path \\ default_path()) do
    case File.read(path) do
      {:ok, secret} ->
        String.trim(secret)

      {:error, :enoent} ->
        secret = :crypto.strong_rand_bytes(48) |> Base.encode64()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, secret)
        File.chmod!(path, 0o600)
        secret
    end
  end

  def default_path, do: Path.join(CmsHarness.Config.local_state_dir(), "desktop_secret")
end
