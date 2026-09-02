defmodule CodeMySpec.Generators.PlaintextEnvFilesTest do
  @moduledoc """
  A plaintext env file only fails the deploy-readiness check if it can
  actually reach git or the image — not merely by existing.

  Found live adopting broken_oaths: it keeps a local `.env` for dev-only
  secrets CodeMySpec has nowhere else to put (there is no `envs/dev.enc.env`
  equivalent — devops levels only cover uat/prod), already excluded from
  both git and the built image. `deploy_ready/1` is a hard, unconditional
  gate with no override, so flagging mere presence blocked a real deploy
  over a file that could never have shipped.
  """

  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Environments.{Environment, Local}
  alias CodeMySpec.Generators.DeployBoilerplate
  alias CodeMySpec.Users.Scope

  setup do
    previous = Application.get_env(:code_my_spec, :environment)
    Application.put_env(:code_my_spec, :environment, Local)
    on_exit(fn -> Application.put_env(:code_my_spec, :environment, previous) end)

    {:ok, dir} = Briefly.create(directory: true)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)

    scope = %Scope{active_project_id: nil, environment: Environment.new(:local, dir)}
    %{scope: scope, dir: dir}
  end

  test "an .env not excluded from either git or docker still fails", %{scope: scope, dir: dir} do
    File.write!(Path.join(dir, ".env"), "SECRET=1\n")

    assert DeployBoilerplate.plaintext_env_files(scope) == [".env"]
  end

  test "an .env gitignored but not dockerignored still fails", %{scope: scope, dir: dir} do
    File.write!(Path.join(dir, ".env"), "SECRET=1\n")
    File.write!(Path.join(dir, ".gitignore"), ".env\n")

    assert DeployBoilerplate.plaintext_env_files(scope) == [".env"]
  end

  test "an .env dockerignored but not gitignored still fails", %{scope: scope, dir: dir} do
    File.write!(Path.join(dir, ".env"), "SECRET=1\n")
    File.write!(Path.join(dir, ".dockerignore"), ".env*\n")

    assert DeployBoilerplate.plaintext_env_files(scope) == [".env"]
  end

  test "an .env excluded from both git and docker does not fail", %{scope: scope, dir: dir} do
    File.write!(Path.join(dir, ".env"), "SECRET=1\n")
    File.write!(Path.join(dir, ".gitignore"), ".env\n")
    File.write!(Path.join(dir, ".dockerignore"), ".env*\n")

    assert DeployBoilerplate.plaintext_env_files(scope) == []
  end

  test "a .dockerignore wildcard pattern matches the real filename", %{scope: scope, dir: dir} do
    File.write!(Path.join(dir, ".env.local"), "SECRET=1\n")
    File.write!(Path.join(dir, ".gitignore"), ".env*\n")
    File.write!(Path.join(dir, ".dockerignore"), ".env*\n")

    assert DeployBoilerplate.plaintext_env_files(scope) == []
  end

  test "no plaintext env files present is fine", %{scope: scope} do
    assert DeployBoilerplate.plaintext_env_files(scope) == []
  end
end
