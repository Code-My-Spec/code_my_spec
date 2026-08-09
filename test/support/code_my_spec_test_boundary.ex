defmodule CodeMySpecTest do
  @moduledoc false

  # `FakeWorkspaceRunner` is exported so `CodeMySpecSpex.Fixtures` can install
  # and drive it. This does not open it to spex: Boundary needs the dep *and*
  # the export, and `CodeMySpecSpex` carries no `CodeMySpecTest` dep — reaching
  # into test support is the bridge's job, not a criterion's.
  #
  # Boundary flags cross-boundary *calls*, not module references, which is why
  # naming this module in config and handing it to `start_supervised!` has
  # always passed while `FakeWorkspaceRunner.put_serving/1` from a spex did not.
  use Boundary, top_level?: true, deps: [CodeMySpec], exports: [FakeWorkspaceRunner]
end
