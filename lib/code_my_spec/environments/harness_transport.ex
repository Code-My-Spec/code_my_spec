defmodule CodeMySpec.Environments.HarnessTransport do
  @moduledoc """
  How `Environments.Harness` reaches a harness, supplied from outside.

  `Environments` is a leaf — `deps: []`, and every other boundary
  including `CodeMySpec` itself depends on it. The registry that knows
  which process serves a harness lives in `CodeMySpec.Analysis`, so
  naming it here would close a cycle, and Boundary says so. It is also
  the wrong shape independently: `cms_harness` links `Environments`
  and has no business carrying the server's analysis code.

  So the leaf declares what it needs and the application says who
  provides it (`config :code_my_spec, :harness_fs_transport`). One
  callback, because there is one thing to do: carry an operation to a
  harness and bring the answer back.
  """

  @doc """
  Perform `op` with `payload` on the working copy `harness_id` serves.

  Returns whatever the operation returns — `Environments` results pass
  through unchanged — or `{:error, :harness_unreachable}` when no
  process is serving that harness.
  """
  @callback harness_fs_request(
              harness_id :: String.t(),
              op :: String.t(),
              payload :: map(),
              timeout :: timeout()
            ) :: {:ok, term()} | :ok | {:error, term()}
end
