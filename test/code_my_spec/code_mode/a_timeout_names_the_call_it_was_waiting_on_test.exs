defmodule CodeMySpec.CodeMode.ATimeoutNamesTheCallItWasWaitingOnTest do
  @moduledoc """
  A script stopped at its deadline says which tool call was still waiting.

  7fe2d0fa: a QA script chained a click and three waits under one deadline,
  one of them hung, and the answer was only that the script "ran longer than
  it is allowed to". Nothing said which call, and everything it had gathered
  was gone.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.CodeMode
  alias CodeMySpec.CodeMode.Catalog

  defp catalog do
    Catalog.from(
      [
        %{name: "browser_navigate", description: "Go to a URL"},
        %{name: "browser_wait_for_text", description: "Wait until text appears"}
      ],
      fn
        %{name: "browser_wait_for_text"} ->
          fn _args ->
            receive do
              :never_sent -> {:ok, "unreachable"}
            end
          end

        _tool ->
          fn _args -> {:ok, "Navigated"} end
      end,
      nil
    )
  end

  @script """
  browser_navigate({ url = "http://localhost/dev-boxes" })
  print("on dev boxes")
  browser_wait_for_text({ text = "added" })
  return "done"
  """

  # Run once: the deadline has to outlast building the sandbox on a loaded
  # machine, or it fires before the first call and the script truthfully
  # reports nothing in flight.
  setup_all do
    %{error: CodeMode.eval(catalog(), @script, timeout: 5_000).error}
  end

  test "the timeout names the call that never answered", %{error: error} do
    assert error.kind == :timeout
    assert error.message =~ "Still waiting on `browser_wait_for_text`"
  end

  test "and lists what finished before it", %{error: error} do
    assert error.message =~ ~r/Finished before it: browser_navigate \(\d+ms\)/
  end

  test "and keeps what the script printed", %{error: error} do
    assert error.message =~ "Printed:\non dev boxes"
  end
end
