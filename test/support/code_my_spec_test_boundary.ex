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
  # `CmsHarness` is here for the in-process doubles and nothing else.
  # `InProcessDeviceClient` implements a harness behaviour and
  # `InProcessAgentTransport` implements a server one while calling the
  # harness — standing in the seam is what an in-process double *is*, and the
  # alternative is a socket in the middle of every test that has one.
  use Boundary,
    top_level?: true,
    # `CmsHarnessTest.Machine` owns "make sure the agent tree exists". The
    # in-process transport starts real agents through it, and a second copy of
    # that setup is how one test's supervisor ended up holding another test's
    # agents.
    deps: [CodeMySpec, CmsHarness, CmsHarnessTest],
    exports: [FakeWorkspaceRunner, PreviewWsClient, WorkspaceWatchers]
end
