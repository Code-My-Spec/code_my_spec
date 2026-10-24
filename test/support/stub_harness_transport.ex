defmodule CodeMySpec.Support.StubHarnessTransport do
  @moduledoc """
  A harness transport that answers `stat` and refuses everything else.

  Enough for `file_exists?/2` to be true, which is what gets a caller past the
  "does this directory exist" guard and into the code that actually talks to a
  working copy. Without it a test against a `:harness` environment stops at the
  first existence check and never reaches the line under test — which is how an
  early regression test passed against the unfixed code.

  A top-level module rather than one nested in a test: fakes live in
  `test/support` beside the other ones, and a nested module has to be reached
  through `__MODULE__.` at every call site.

  Named under `CodeMySpec.Support` rather than `CodeMySpecTest`, which is where
  `InMemoryExecutionContext` and `RecordingExecutionContext` already sit for the same
  reason: the `CodeMySpecTest` boundary may not reference
  `CodeMySpec.ExecutionContexts`, and a stub of an ExecutionContexts behaviour has to.
  """

  @behaviour CodeMySpec.ExecutionContexts.HarnessTransport

  @impl true
  def harness_fs_request(_id, "stat", _payload, _timeout), do: {:ok, %{"size" => 0}}
  def harness_fs_request(_id, _op, _payload, _timeout), do: {:error, :harness_unreachable}
end
