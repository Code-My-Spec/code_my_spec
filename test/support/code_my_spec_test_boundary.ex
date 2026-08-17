defmodule CodeMySpecTest do
  @moduledoc false

  # These are exported so `CodeMySpecSpex.Fixtures` can install and drive them.
  # That does not open them to spex: Boundary needs the dep *and* the export,
  # and `CodeMySpecSpex` carries no `CodeMySpecTest` dep — reaching into test
  # support is the bridge's job, not a criterion's.
  #
  # Boundary flags cross-boundary *calls*, not module references, which is why
  # naming a module in config and handing it to `start_supervised!` has always
  # passed while `FakeWorkspaceRunner.put_serving/1` from a spex did not.
  #
  # `PreviewWsClient` is the browser's end of story 886's preview socket. It is
  # a client the bridge drives, not something a criterion should be holding.
  #
  # `WorkspaceWatchers` is the teardown for the tasks `Workspaces.boot/1`
  # leaves polling. The bridge has to order that teardown against the fake
  # runner it starts, so it needs to name it; a criterion never does.
  use Boundary,
    top_level?: true,
    deps: [CodeMySpec],
    exports: [FakeWorkspaceRunner, PreviewWsClient, WorkspaceWatchers]
end
