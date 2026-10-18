defmodule CodeMySpec.Provisioning.Tools.ReadDatabaseUrl do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning.Database
  alias CodeMySpec.Resources

  @impl true
  def name, do: "read_database_url"

  @impl true
  def description do
    """
    The connection string `:server` already minted for this environment's
    database.

    `Database.serve/3` mints and stores this project's role/database
    credential in `ProjectSecrets` the moment it provisions the container and
    tenant — before the step ever reaches the part that writes it into
    `envs/*.enc.env`, which is real local-filesystem work a project with no
    checkout on this side cannot complete (the same wall `:repository` hits).
    This is the read half of that gap: the credential already exists, and a
    caller with a real checkout elsewhere needs the value itself to encrypt it
    there, rather than this server minting it a second time somewhere it
    cannot commit anything.

    ## The value is unverified

    This reads `ProjectSecrets` alone — it does not check that the role or
    database the credential names still exists on the box. `serve/3`'s own
    `sync_password/2` runs unconditionally on every `:server` step, so "run
    :server, then read this" is always current; read on its own after the box
    has been touched independently (recreated, restored, migrated to a new
    server) can hand back a credential for a tenant that no longer exists,
    with nothing here to say so.
    """
  end

  @impl true
  def params do
    %{
      environment:
        {:required,
         {:meta, :string, [description: "Environment name, e.g. \"prod\" or \"uat\"."]}}
    }
  end

  @impl true
  def call(%{environment: environment}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      scope
      |> Resources.project_scope(project)
      |> Database.credential(environment)
      |> reply()
    else
      {:error, reason} -> error(reason)
    end
  end

  defp reply({:ok, credential}), do: ok(Database.url(credential))
  defp reply({:error, reason}), do: error(reason)

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not read the database URL: #{inspect(reason)}"}
end
