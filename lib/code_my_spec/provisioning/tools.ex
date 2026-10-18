defmodule CodeMySpec.Provisioning.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Activity,
      CodeMySpec.Agents,
      CodeMySpec.Environments,
      CodeMySpec.Generators,
      CodeMySpec.LocalScope,
      CodeMySpec.Provisioning,
      CodeMySpec.Provisioning.EnvironmentRepository,
      CodeMySpec.ProvisioningPlan,
      CodeMySpec.Resources,
      CodeMySpec.Servers,
      CodeMySpec.Telemetry,
      CodeMySpec.Tools,
      CodeMySpec.WorkingCopies
    ]

  def all do
    [
      CodeMySpec.Provisioning.Tools.AdoptRepository,
      CodeMySpec.Provisioning.Tools.DevopsStatus,
      CodeMySpec.Provisioning.Tools.EnsureEnvironment,
      CodeMySpec.Provisioning.Tools.EnsureServerAccessKey,
      CodeMySpec.Provisioning.Tools.GenerateDeployFiles,
      CodeMySpec.Provisioning.Tools.ImportAgeKey,
      CodeMySpec.Provisioning.Tools.LinkServer,
      CodeMySpec.Provisioning.Tools.ProviderRequest,
      CodeMySpec.Provisioning.Tools.ProvisionAccountServer,
      CodeMySpec.Provisioning.Tools.QueryTelemetry,
      CodeMySpec.Provisioning.Tools.ReadDatabaseUrl,
      CodeMySpec.Provisioning.Tools.ReadProjectFile,
      CodeMySpec.Provisioning.Tools.ReadRegistryCredential,
      CodeMySpec.Provisioning.Tools.RunDevopsSetup,
      CodeMySpec.Provisioning.Tools.RunProvisioningStep,
      CodeMySpec.Provisioning.Tools.SaveProviderCredential,
      CodeMySpec.Provisioning.Tools.WriteProjectFile
    ]
  end
end
