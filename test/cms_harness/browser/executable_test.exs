defmodule CmsHarness.Browser.ExecutableTest do
  @moduledoc """
  `vibium` on PATH is a Node script that runs a Go binary and waits on it, so
  every copy's browser was two processes, ~40 MB of them Node. The harness
  launches the binary the script would have run.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Browser.Executable

  @moduletag :tmp_dir

  @mac %{os: "darwin", arch: "arm64"}
  @windows %{os: "win32", arch: "x64"}

  defp touch(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    path
  end

  # `npm install -g vibium` under a Homebrew or nvm prefix: bin/vibium is a
  # relative symlink to the package's cli.js.
  defp unix_prefix(prefix) do
    pkg = Path.join(prefix, "lib/node_modules/vibium")
    touch(Path.join(pkg, "bin/cli.js"))
    shim = Path.join(prefix, "bin/vibium")
    File.mkdir_p!(Path.dirname(shim))
    File.ln_s!("../lib/node_modules/vibium/bin/cli.js", shim)
    {shim, pkg}
  end

  test "a symlinked shim resolves to the platform binary nested in the package", %{
    tmp_dir: tmp
  } do
    {shim, pkg} = unix_prefix(tmp)
    binary = touch(Path.join(pkg, "node_modules/@vibium/darwin-arm64/bin/vibium"))

    assert Executable.resolve(shim, @mac) == binary
  end

  test "a hoisted platform package beside the vibium package is found too", %{tmp_dir: tmp} do
    {shim, _pkg} = unix_prefix(tmp)
    binary = touch(Path.join(tmp, "lib/node_modules/@vibium/linux-x64/bin/vibium"))

    assert Executable.resolve(shim, %{os: "linux", arch: "x64"}) == binary
  end

  test "another platform's binary is not taken for this one", %{tmp_dir: tmp} do
    {shim, pkg} = unix_prefix(tmp)
    touch(Path.join(pkg, "node_modules/@vibium/darwin-x64/bin/vibium"))

    assert Executable.resolve(shim, @mac) == shim
  end

  test "no platform package falls back to the command on PATH", %{tmp_dir: tmp} do
    {shim, _pkg} = unix_prefix(tmp)

    assert Executable.resolve(shim, @mac) == shim
  end

  test "a vibium on PATH that is the binary itself stays itself", %{tmp_dir: tmp} do
    binary = touch(Path.join(tmp, "opt/vibium"))

    assert Executable.resolve(binary, @mac) == binary
  end

  test "no vibium at all stays no vibium" do
    assert Executable.resolve(nil, @mac) == nil
  end

  # npm on Windows writes vibium.cmd into the prefix itself, beside
  # node_modules, with no symlink; the binary is vibium.exe.
  test "the Windows layout finds vibium.exe beside vibium.cmd", %{tmp_dir: tmp} do
    shim = touch(Path.join(tmp, "npm/vibium.cmd"))
    pkg = Path.join(tmp, "npm/node_modules/vibium")
    touch(Path.join(pkg, "bin/cli.js"))
    touch(Path.join(pkg, "node_modules/@vibium/win32-x64/bin/vibium"))
    binary = touch(Path.join(pkg, "node_modules/@vibium/win32-x64/bin/vibium.exe"))

    assert Executable.resolve(shim, @windows) == binary
  end

  test "Windows without the platform package falls back to vibium.cmd", %{tmp_dir: tmp} do
    shim = touch(Path.join(tmp, "npm/vibium.cmd"))
    touch(Path.join(tmp, "npm/node_modules/vibium/bin/cli.js"))

    assert Executable.resolve(shim, @windows) == shim
  end

  test "the host is named the way Node names it" do
    %{os: os, arch: arch} = Executable.host()

    assert os in ["darwin", "linux", "win32", "freebsd"]
    assert arch in ["x64", "arm64"]
  end
end
