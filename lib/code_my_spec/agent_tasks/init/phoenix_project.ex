defmodule CodeMySpec.AgentTasks.Init.PhoenixProject do
  @moduledoc """
  Init step: verify a Phoenix project exists (mix.exs, lib/, config/).
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  def evaluate(scope, _task) do
    dir = working_dir(scope)
    env = environment(scope)

    missing =
      ["mix.exs", "lib", "config"]
      |> Enum.reject(&Environments.file_exists?(env, &1))
      |> Enum.map(fn
        "mix.exs" -> "mix.exs"
        dirname -> dirname <> "/"
      end)

    if missing == [],
      do: {:ok, :valid},
      else: {:ok, :invalid, "No Phoenix project at `#{dir}` — missing: #{Enum.join(missing, ", ")}"}
  end

  def command(scope, _task) do
    dir = working_dir(scope)

    {:ok, """
    # Phoenix Project Required

    CodeMySpec attached to `#{dir}`, but it doesn't look like a Phoenix project
    (no `mix.exs`, `lib/`, and `config/`).

    ## Most likely fix: wrong directory

    If you have an existing Phoenix project, the cause is almost always that
    Claude Code was launched from outside its root. The fix:

    1. **Quit this Claude Code session.**
    2. **`cd` into your Phoenix project root** (the folder with `mix.exs`).
    3. **Re-launch Claude Code from there**, then re-run `/codemyspec:init`.

    CodeMySpec attaches to whatever directory Claude Code is running in — there's
    no project picker beyond `cd`.

    ## Otherwise: create a new Phoenix project

    Only do this if you intend the **current directory** to become a fresh
    Phoenix app. This will scaffold files into `#{dir}`:

    ```bash
    mix phx.new . --app your_app_name
    ```

    Or in a new sibling directory:

    ```bash
    mix phx.new your_app_name
    cd your_app_name
    ```

    After creation:

    ```bash
    mix deps.get
    mix ecto.create
    ```
    """}
  end

  defp working_dir(scope) do
    scope.cwd || File.cwd!()
  end

  # `working_dir/1` stays for the message text — the agent needs to be told which
  # directory was checked — but the existence check itself goes through the
  # environment, so "is there a Phoenix project here" is asked of the machine
  # that holds the working copy rather than the one running the evaluation.
  defp environment(%{environment: %Environment{} = env}), do: env
  defp environment(scope), do: Environment.new(:local, working_dir(scope))
end
