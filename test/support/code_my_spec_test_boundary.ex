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
  use Boundary,
    top_level?: true,
    # `CmsHarnessTest.Machine` owns "make sure the agent tree exists". The
    # in-process transport starts real agents through it, and a second copy of
    # that setup is how one test's supervisor ended up holding another test's
    # agents.
    # `CodeMySpec.McpServers` because `InVmMcpTransport` stands in for the wire
    # between the harness and the server, which means touching both sides of it.
    # That is exactly why it lives here rather than beside the real transport:
    # `CmsHarness` may not reference the MCP layer, and a test double for a wire
    # has to.
    deps: [CodeMySpec, CodeMySpec.McpServers, CmsHarness, CmsHarnessTest],
    exports: [FakeWorkspaceRunner, WorkspaceWatchers]
end
