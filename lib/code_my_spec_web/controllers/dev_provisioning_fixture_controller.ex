defmodule CodeMySpecWeb.DevProvisioningFixtureController do
  @moduledoc "Development-only disposable setup fixtures and simulated provider controls."
  use CodeMySpecWeb, :controller

  alias CodeMySpec.{Projects, Users, UserPreferences}
  alias CodeMySpec.Provisioning.QaFixture

  def create(conn, params) do
    with {:ok, scope} <- authenticate(params),
         {:ok, project} <-
           Projects.create_project(scope, %{
             name: "QA Setup #{Ecto.UUID.generate()}",
             module_name: "QaSetup",
             description: "QA provisioning simulator; requires an active development fixture.",
             domain: "setup-qa.invalid",
             setup_options: ~w(server domain email storage)
           }),
         :ok <- QaFixture.register(project.id, scope.active_account_id) do
      json(conn, %{
        project_id: project.id,
        account_id: scope.active_account_id,
        simulated: true,
        console_path: "/app/projects/#{project.id}/console"
      })
    else
      _ -> refuse(conn)
    end
  end

  def inspect_fixture(conn, params) do
    with {:ok, scope} <- authenticate(params),
         {:ok, _project} <- Projects.get_project(scope, params["project_id"]),
         {:ok, snapshot} <- QaFixture.snapshot(params["project_id"]) do
      json(conn, snapshot)
    else
      _ -> refuse(conn)
    end
  end

  def control(conn, params) do
    with {:ok, scope} <- authenticate(params),
         {:ok, _project} <- Projects.get_project(scope, params["project_id"]),
         :ok <-
           QaFixture.control(
             params["project_id"],
             params["step"],
             params["action"],
             params["environment"]
           ),
         {:ok, snapshot} <- QaFixture.snapshot(params["project_id"]) do
      json(conn, snapshot)
    else
      _ -> refuse(conn)
    end
  end

  defp authenticate(%{"email" => email, "password" => password})
       when is_binary(email) and is_binary(password) do
    case Users.get_user_by_email_and_password(email, password) do
      nil ->
        {:error, :unauthorized}

      user ->
        case UserPreferences.scope_for(user) do
          %{active_account_id: id} = scope when is_binary(id) -> {:ok, scope}
          _ -> {:error, :select_account_first}
        end
    end
  end

  defp authenticate(_), do: {:error, :unauthorized}

  defp refuse(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error:
        "Use valid credentials, select an account, and address a registered fixture with a valid control."
    })
  end
end
