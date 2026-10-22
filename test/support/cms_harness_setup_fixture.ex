defmodule CmsHarnessTest.SetupFixture do
  @moduledoc "Explicit provisioning actions for acceptance specs, independent of desktop startup."
  defdelegate check_prerequisites(opts), to: CmsHarness.Setup
  defdelegate status(opts), to: CmsHarness.Setup
  defdelegate connect_project(path, identity, opts), to: CmsHarness.Setup
  defdelegate agent_installations(root), to: CmsHarness.Setup.Prerequisites
end
