defmodule CodeMySpec.BootVersionConfigTest do
  @moduledoc """
  The one property of `config_changed?/2` with a consequence: it must not guess.

  `5fb011f4`. A `config/*.exs` commit leaves every running dev server answering
  `could not compile application` to every request, in a different checkout,
  minutes later, to whoever arrives next. The server that breaks is the one that
  can state this as a fact — it knows the commit it booted from and the commit
  on disk — and the stop hook turns that into a sentence.

  When the range cannot be read the answer has to be `:unknown`. A confident
  `false` sends someone whose server is genuinely wedged off to look at their
  network, which is worse than saying nothing.

  ## Why the positive case is not here

  It was, and it built a real repository in `tmp` and ran `git init`, `git
  commit` and `git rev-parse` to do it. That is the same class of test that
  produced six rounds of `** (EXIT …) killed` noise in this suite — shelling out
  to real tools makes a test non-deterministic and makes it fail for reasons
  that have nothing to do with the code. Written while diagnosing exactly that,
  which is the least excusable time to write one.

  What is left needs no subprocess at all: an unreadable root short-circuits
  before `System.cmd` is reached. Covering "a config commit is detected" against
  a live repository is not worth putting another live `git` in the suite; the
  behaviour is one `git diff --name-only … -- config` and the decision it feeds
  is asserted in `problem_renderer` and `hooks/stop` tests that use no
  subprocess.
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.BootVersion

  @key {CodeMySpec.BootVersion, :boot}

  setup do
    on_exit(fn -> :persistent_term.erase(@key) end)
    :ok
  end

  test "a root that cannot be read answers :unknown, never false" do
    :persistent_term.put(@key, {"/nonexistent/checkout", "abc1234"})

    assert BootVersion.config_changed?("abc1234", "def5678") == :unknown,
           "a range that could not be read answered as though it had been. " <>
             "`false` here reads as `your server is fine`, and the reader whose " <>
             "server is wedged goes looking for a cause that is not there."
  end

  test "no captured boot answers :unknown" do
    :persistent_term.erase(@key)

    assert BootVersion.config_changed?("abc1234", "def5678") == :unknown
  end
end
