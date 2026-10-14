defmodule CmsHarness.Setup.Connection do
  @moduledoc "Configures a validated checkout using identities issued by the server."

  alias ClientUtils.Harness.Onboarding
  alias CmsHarness.{Config, HarnessConfig, ProjectIdentity, Projects}
  alias CmsHarness.Setup.Project
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  @spec connect(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def connect(path, %{project_id: project_id, working_copy_id: copy_id, app: app})
      when is_binary(project_id) and project_id != "" and
             is_binary(copy_id) and copy_id != "" and is_binary(app) and app != "" do
    with {:ok, root} <- Project.validate(path),
         :ok <- same_project(root, project_id),
         :ok <- same_copy(root, copy_id),
         :ok <- same_server(root, Config.server_url()),
         :ok <-
           HarnessConfig.write(root, %{
             working_copy_id: copy_id,
             project_id: project_id,
             server_url: Config.server_url()
           }),
         :ok <- configure(root, copy_id, app),
         {:ok, identity} <- Projects.ensure_started(root) do
      {:ok, Map.put(identity, :connected, Projects.connected?(root))}
    end
  end

  def connect(_path, _identity), do: {:error, :issued_project_and_working_copy_required}

  defp same_project(root, expected) do
    case ProjectIdentity.resolve(root) do
      {:ok, %{id: ^expected}} -> :ok
      {:ok, %{id: other}} -> {:error, {:project_identity_conflict, other}}
      {:error, :no_project_id} -> :ok
      {:error, _} = error -> error
    end
  end

  defp same_copy(root, expected) do
    case HarnessConfig.read_file(root) do
      :none -> :ok
      {:ok, %{working_copy_id: ^expected}} -> :ok
      {:ok, %{working_copy_id: nil}} -> :ok
      {:ok, %{working_copy_id: other}} -> {:error, {:working_copy_identity_conflict, other}}
      {:error, _} = error -> error
    end
  end

  defp same_server(root, expected) do
    case HarnessConfig.read_file(root) do
      :none -> :ok
      {:ok, %{server_url: nil}} -> :ok
      {:ok, %{server_url: ^expected}} -> :ok
      {:ok, %{server_url: other}} -> {:error, {:server_identity_conflict, other}}
      {:error, _} = error -> error
    end
  end

  defp configure(root, copy_id, app) do
    report =
      Onboarding.onboard(root,
        io: {Environments, Environment.new(:local, root)},
        app: app,
        harness_id: copy_id,
        relay_model_turns: false
      )

    case report do
      %{settings: {:error, reason}} -> {:error, {:onboarding_settings, reason}}
      %{hooks: {:error, reason}} -> {:error, {:onboarding_hooks, reason}}
      _ -> verify_configuration(root)
    end
  end

  defp verify_configuration(root) do
    case Onboarding.check(root, io: {Environments, Environment.new(:local, root)}) do
      %{onboarded: true} -> :ok
      %{missing: missing} -> {:error, {:incomplete_onboarding, missing}}
    end
  end
end
