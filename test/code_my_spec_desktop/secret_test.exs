defmodule CodeMySpecDesktop.SecretTest do
  use ExUnit.Case, async: true

  alias CodeMySpecDesktop.Secret

  @moduletag :tmp_dir

  test "creates a secret on first read and returns the same one after", %{tmp_dir: dir} do
    path = Path.join([dir, "state", "desktop_secret"])

    secret = Secret.read_or_create!(path)

    assert byte_size(Base.decode64!(secret)) == 48
    assert File.read!(path) == secret
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert Secret.read_or_create!(path) == secret
  end

  test "reads an existing secret as written", %{tmp_dir: dir} do
    path = Path.join(dir, "desktop_secret")
    File.write!(path, "kept\n")

    assert Secret.read_or_create!(path) == "kept"
  end
end
