defmodule CodeMySpecLocalWeb.InitController do
  @moduledoc """
  Bootstrap entry point for `/codemyspec:init`.

  Init must run *before* a project is linked, so it lives on its own route
  with the cwd-only `WorkingDirCwdScope` plug instead of the project-required
  `WorkingDirScope` used by `/api/skills/start`. It handles only the init
  surface: the plain bootstrap task and the `auth` sub-flow. `sync` is its
  own skill (`/codemyspec:sync`).
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.AgentTasks.StartAgentTask

  def start(conn, params) do
    case subcommand(params["arguments"]) do
      "auth" ->
        json(conn, %{auth: true})

      nil ->
        run_init(conn, params["external_id"])

      other ->
        conn
        |> put_status(400)
        |> json(%{error: "Unknown subcommand '#{other}' for /codemyspec:init", available: ["auth"]})
    end
  end

  defp run_init(conn, external_id) do
    scope = conn.assigns.current_scope

    case StartAgentTask.run(scope, %{
           external_id: external_id,
           session_type: "init",
           module_name: nil
         }) do
      {:ok, prompt, _sync_result} ->
        json(conn, %{prompt: prompt})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  # First whitespace-delimited token of the positional `arguments` string,
  # mirroring SkillController.split_arguments/1. `nil`/`""` → nil (plain init).
  defp subcommand(nil), do: nil

  defp subcommand(args) when is_binary(args) do
    case String.split(String.trim(args), ~r/\s+/, parts: 2) do
      [""] -> nil
      [sub | _] -> sub
    end
  end
end
