defmodule CodeMySpec.Projects.ProjectTest do
  @moduledoc """
  85e42f92: a crash report returned to an agent inspected the full Scope,
  and the project's `deploy_key` -- decrypted into plain text the moment the
  struct is loaded -- printed verbatim. `redact: true` on the secret fields
  makes Ecto derive `Inspect` to hide them wherever this struct (or anything
  holding one, such as `Scope.active_project`) is inspected.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Users.Scope

  @deploy_key "a-real-looking-deploy-key-should-never-print"
  @aws_key_id "fake-aws-access-key-id-should-never-print"
  @aws_secret "aws-secret-should-never-print"

  defp secret_project do
    %Project{
      name: "some name",
      deploy_key: @deploy_key,
      aws_access_key_id: @aws_key_id,
      aws_secret_access_key: @aws_secret
    }
  end

  test "inspecting a project never prints its secret fields" do
    output = inspect(secret_project(), limit: :infinity, printable_limit: :infinity)

    refute output =~ @deploy_key
    refute output =~ @aws_key_id
    refute output =~ @aws_secret
    refute output =~ "deploy_key:"
    refute output =~ "aws_access_key_id:"
    refute output =~ "aws_secret_access_key:"
    assert output =~ "some name"
  end

  test "inspecting a scope carrying that project never prints its secret fields either" do
    scope = %Scope{active_project: secret_project(), active_project_id: "proj-1"}

    output = inspect(scope, limit: :infinity, printable_limit: :infinity)

    refute output =~ @deploy_key
    refute output =~ @aws_key_id
    refute output =~ @aws_secret
  end
end
