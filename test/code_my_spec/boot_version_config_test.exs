defmodule CodeMySpec.BootVersionConfigTest do
  @moduledoc """
  `config_changed?/2` against a real repository, because the answer is a `git
  diff` and a stubbed one would only prove the stub.

  What it guards is 5fb011f4: a `config/*.exs` commit leaves every running dev
  server answering `could not compile application` to every request, in a
  different checkout, minutes later, to whoever arrives next. The server that
  breaks is the one that can state this as a fact — it knows the commit it
  booted from and the commit on disk — so this is the lookup the stop hook turns
  into a sentence.

  No database, so nothing here shares a sandbox with anything. `async: false`
  only because `capture/1` writes node-global `:persistent_term`, which is
  restored on exit.
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.BootVersion

  @key {CodeMySpec.BootVersion, :boot}

  setup do
    previous = :persistent_term.get(@key, :none)

    on_exit(fn -> restore(previous) end)

    root = Path.join(System.tmp_dir!(), "boot-version-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "config"))
    File.mkdir_p!(Path.join(root, "lib"))

    git!(root, ["init", "--quiet"])
    git!(root, ["config", "user.email", "test@example.com"])
    git!(root, ["config", "user.name", "Test"])

    File.write!(Path.join(root, "config/dev.exs"), "import Config\n")
    File.write!(Path.join(root, "lib/thing.ex"), "defmodule Thing, do: nil\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "--quiet", "-m", "base"])

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, base: head(root)}
  end

  test "a commit touching config is reported", %{root: root, base: base} do
    BootVersion.capture(root)

    File.write!(Path.join(root, "config/dev.exs"), "import Config\nconfig :app, key: 1\n")
    git!(root, ["commit", "--quiet", "-am", "add a config block"])

    assert BootVersion.config_changed?(base, head(root)),
           "a config commit went unreported, so the next agent to stop against " <>
             "this server learns it is wedged from a CompileError page that names " <>
             "neither the commit nor the checkout it came from."
  end

  test "a commit that leaves config alone is not reported", %{root: root, base: base} do
    BootVersion.capture(root)

    File.write!(Path.join(root, "lib/thing.ex"), "defmodule Thing, do: :ok\n")
    git!(root, ["commit", "--quiet", "-am", "ordinary work"])

    refute BootVersion.config_changed?(base, head(root)),
           "an ordinary commit was reported as wedging the server. This fires on " <>
             "every stop until a restart, so a false one trains the reader to skip " <>
             "the footer — which is the same as not having it."
  end

  test "an unreadable range is :unknown rather than a guess", %{root: root} do
    BootVersion.capture(root)

    assert BootVersion.config_changed?("deadbee", head(root)) == :unknown,
           "a range that cannot be read answered as though it had been. A " <>
             "confident `false` here sends someone whose server is genuinely " <>
             "wedged off to look at their network."
  end

  defp restore(:none), do: :persistent_term.erase(@key)
  defp restore(value), do: :persistent_term.put(@key, value)

  defp git!(root, args) do
    {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    :ok
  end

  defp head(root) do
    {sha, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: root)
    String.trim(sha)
  end
end
