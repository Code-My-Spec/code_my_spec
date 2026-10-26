defmodule CmsHarness.ARemovedCheckoutsDatabasesGoWithItTest do
  @moduledoc """
  A working copy's databases are dropped when its checkout goes. Nothing did,
  and 99 test partitions and app clones of copies long gone filled the disk
  (issue d4747513). They are found by the root's digest, so a removed checkout
  whose `mix.exs` cannot be read still loses its own and nobody else's.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.CopyDatabases
  alias CmsHarnessTest.FakeAppInstanceRunner

  @root "/Users/someone/github/project-gate"

  setup do
    prior = Application.get_env(:code_my_spec, CopyDatabases)
    Application.put_env(:code_my_spec, CopyDatabases, runner: FakeAppInstanceRunner)
    on_exit(fn -> Application.put_env(:code_my_spec, CopyDatabases, prior) end)
    start_supervised!(FakeAppInstanceRunner)
    :ok
  end

  defp digest,
    do: :crypto.hash(:sha256, @root) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  test "its test partitions and its app clone are dropped, found by the root's digest" do
    mine = [
      "app_testh#{digest()}",
      "app_testh#{digest()}s_3",
      "app_dev_wc_#{digest()}"
    ]

    FakeAppInstanceRunner.put_idle_databases(mine)

    assert CopyDatabases.drop_for_root(@root) == mine

    calls = FakeAppInstanceRunner.calls()

    assert [{:idle_databases_matching, [regex]}] =
             Enum.filter(calls, &(elem(&1, 0) == :idle_databases_matching))

    assert regex =~ "_testh#{digest()}"
    assert regex =~ "_dev_wc_#{digest()}"
    assert for({:drop_database, [db]} <- calls, do: db) == mine

    # The pattern names this root's digest only: another copy's survive.
    {:ok, compiled} = Regex.compile(regex)
    assert Regex.match?(compiled, "code_my_spec_testh#{digest()}a")
    refute Regex.match?(compiled, "code_my_spec_testh0f9f7c71s")
  end
end
