defmodule CodeMySpec.AgentTasks.Setup.ProjectStructure do
  @moduledoc """
  Setup step: .code_my_spec/ directory structure exists.

  Directories aren't tracked as `File` records (FileSync syncs files), so this
  step is the one that reaches past them. It asks `Context.dir_status/2`, which
  proves a directory from the synced files inside it where it can and stats only
  where it must — and says `:unobservable` rather than `:absent` when there is no
  disk to stat, which is the normal case on the light harness.
  """

  alias CodeMySpec.AgentTasks.Setup.{Context, Helpers}

  def check(%Context{} = ctx) do
    base = CodeMySpec.Paths.base_dir()
    app = Context.app_name(ctx)

    required =
      [base, Path.join(base, "rules"), Path.join(base, "spec")] ++
        if app do
          [
            Path.join([base, "spec", app]),
            Path.join([base, "spec", "#{app}_web"])
          ]
        else
          []
        end

    # Only `:absent` counts. `:unobservable` means there is no disk to look at
    # (the light harness), and reporting those as missing makes a step the agent
    # cannot satisfy: directories are not synced, so `mkdir` changes nothing the
    # server can see. Every one of these directories is created by writing the
    # file that belongs in it, and those writes are checked by their own steps —
    # so nothing goes unverified by letting an empty, unseeable directory pass.
    missing = Enum.filter(required, &(Context.dir_status(ctx, &1) == :absent))

    if missing == [],
      do: :valid,
      else: {:invalid, "Missing directories: #{Enum.map_join(missing, ", ", &"`#{&1}`")}"}
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

  def command(scope, _task) do
    app_name = Helpers.app_name(scope)
    base = CodeMySpec.Paths.base_dir()

    {:ok,
     """
     # Create Project Structure

     ```bash
     mkdir -p #{base}/rules #{base}/spec/#{app_name} #{base}/spec/#{app_name}_web
     ```
     """}
  end
end
