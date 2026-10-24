defmodule CodeMySpec.Projects.Tools.SetupLocalProject do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.Projects.{LocalSetup, Tools}

  @impl true
  def name, do: "setup_local_project"
  @impl true
  def description do
    """
    Main's desktop onboarding workflow, available without a working copy. Uses the shared machine
    prerequisite catalog and CodeMySpec Phoenix generator; registers the checkout against THIS
    project, not a new project. Uses the saved local_directory, never agent scratch.
    action=check runs recorded prerequisite checks without installing software. The cms check verifies
    mix help cms.new (the generator archive); desktop does not require a standalone cms executable.
    action=prepare_database explicitly prepares access to the local PostgreSQL development database.
    Use it after installing/starting PostgreSQL when the current OS user's role is missing.
    It records administration command results, never changes passwords or authentication policy,
    and never connects to a remote database. It can create the local role on Linux when running
    as root; other permission failures remain explicit. Run check afterwards to record prerequisites.
    Install commands may take minutes: use Bash's timeout in milliseconds (for example 600000),
    retain output, and verify completion before retrying. Check the generator's Elixir requirement
    before choosing a managed runtime; never use the desktop application's private runtime.
    action=create checks prerequisites, generates via mix cms.new, runs dev setup and connects
    the main checkout. action=connect registers an already generated checkout at the saved path and retries failed dev setup.
    action=refresh observes a pending connection. action=status reads progress/results.
    Work runs in the background; poll status until running=false and inspect result and snapshot.
    Once the checkout connects, the existing Main and Product move into it with their conversations.
    After dev setup succeeds, the workflow enables continuous work for the existing team once.
    Do not start replacement Main or Product agents. A successful dispatch is not readiness. Missing prerequisites and failed dev setup are reported
    with their command results. Fix the reported problem, then retry. Never use production provisioning
    or get_next_requirement as a prerequisite for this initial setup. Only desktop/local is supported.
    """
  end

  @impl true
  def params do
    %{
      action:
        {:required,
         {:meta, {:enum, ~w(status check prepare_database create connect refresh)},
          [description: "status, check, prepare_database, create, connect, or refresh"]}},
      app:
        {:meta, :string,
         [
           description:
             "Optional snake_case OTP app name for generation; defaults from the project's module name."
         ]}
    }
  end

  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.text()
  @impl true
  def script_result(params, context) do
    action = Map.get(params, :action, Map.get(params, "action"))
    app = Map.get(params, :app, Map.get(params, "app"))

    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, result} <- LocalSetup.run(scope, action, app) do
      {:ok, result}
    else
      {:error, reason} -> Tools.error(reason)
    end
  end
end
