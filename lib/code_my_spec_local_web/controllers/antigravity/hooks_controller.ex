defmodule CodeMySpecLocalWeb.Antigravity.HooksController do
  @moduledoc """
  Adapts Google Antigravity hook events onto the CodeMySpec hook pipeline.

  Antigravity hooks speak a different dialect than Claude Code: camelCase
  payloads (`conversationId`, `toolCall.name`/`args`, `workspacePaths`),
  different event names (PreInvocation/PostInvocation instead of
  SessionStart), and different output schemas. Three schema gaps drive the
  design here:

  * **PreToolUse output cannot mutate tool input** (no `updatedInput`), so
    the `mix test`/`mix spex` analysis-service rewrite becomes a
    deny-with-redirect: the agent is told the exact curl to run instead.
    MCP `session_id` enrichment is likewise impossible from the hook —
    Antigravity agents must rely on explicit session context.
  * **PostToolUse carries no tool name/args** (only `stepIdx` + `error`),
    so file-edit tracking happens at PreToolUse time (optimistic — the
    write is about to execute) instead of post-hoc.
  * **Stop maps cleanly**: Claude's `{"decision":"block","reason":…}`
    becomes `{"decision":"continue","reason":…}` and any allow becomes
    `{"decision":"stop"}` — so the full StopController decision tree
    (validation, continuous mode, stuck detection, R5b handoff) is reused
    verbatim via delegation, with the response translated in
    `register_before_send`. Terminus extras (`retrospective`,
    `systemMessage`) have no Antigravity slot and are dropped.

  Sessions are keyed on Antigravity's `conversationId`, which plays the
  role Claude's `session_id` does everywhere downstream.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Hooks.PreToolUse
  alias CodeMySpec.Sessions
  alias CodeMySpecLocalWeb.Hooks.StopController

  # Antigravity file-writing tools all carry the target path as `TargetFile`
  # in toolCall.args.
  @edit_tools ~w(write_to_file replace_file_content multi_replace_file_content)

  # ── PreInvocation ──────────────────────────────────────────────────
  # Fires before every model call; the first invocation of a conversation
  # (`invocationNum` 0) is the closest analog to Claude's SessionStart, so
  # that's when the session row is found-or-created. Output schema only
  # supports `injectSteps`; an empty object is a no-op.

  def pre_invocation(conn, params) do
    with 0 <- Map.get(params, "invocationNum", -1),
         conversation_id when is_binary(conversation_id) <- conversation_id(params) do
      scope = conn.assigns.current_scope

      case Sessions.find_or_create_session(scope, conversation_id) do
        {:ok, _session} ->
          Logger.info("[AntigravityHooks] session ready: #{conversation_id}")

        {:error, reason} ->
          Logger.warning("[AntigravityHooks] session create failed: #{inspect(reason)}")
      end
    end

    json(conn, %{})
  end

  # ── PreToolUse ─────────────────────────────────────────────────────
  # Gate-only (allow/deny/ask). Default is "ask", which preserves
  # Antigravity's normal permission flow including the user's Always
  # Allow settings — never "allow", which would silently auto-approve
  # every tool call.

  def pre_tool_use(conn, params) do
    tool = get_in(params, ["toolCall", "name"])
    args = get_in(params, ["toolCall", "args"]) || %{}

    track_edit(tool, args, conversation_id(params))

    case redirect_test_command(conn, tool, args) do
      {:deny, reason} ->
        Logger.info("[AntigravityHooks] redirecting #{tool} to analysis service")
        json(conn, %{"decision" => "deny", "reason" => reason})

      :pass ->
        json(conn, %{"decision" => "ask"})
    end
  end

  # ── PostToolUse ────────────────────────────────────────────────────
  # No tool identity in the payload — only session recency can be
  # derived. Fire-and-forget; always responds `{}` so execution proceeds.

  def post_tool_use(conn, params) do
    touch_session(conn, conversation_id(params))
    json(conn, %{})
  end

  # ── PostInvocation ─────────────────────────────────────────────────
  # No Claude analog; nothing to do.

  def post_invocation(conn, _params) do
    json(conn, %{})
  end

  # ── Stop ───────────────────────────────────────────────────────────
  # Full reuse of the Claude StopController decision tree; only the
  # response dialect differs.

  def stop(conn, params) do
    translated = %{"session_id" => conversation_id(params)}

    conn
    |> register_before_send(&translate_stop_response/1)
    |> StopController.handle(translated)
  end

  defp translate_stop_response(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{"decision" => "block", "reason" => reason}} ->
        %{conn | resp_body: Jason.encode!(%{"decision" => "continue", "reason" => reason})}

      {:ok, _allow} ->
        %{conn | resp_body: Jason.encode!(%{"decision" => "stop"})}

      _error ->
        conn
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp conversation_id(params) do
    case Map.get(params, "conversationId") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp track_edit(tool, %{"TargetFile" => file_path}, conversation_id)
       when tool in @edit_tools and is_binary(file_path) and is_binary(conversation_id) do
    FileEdits.track_edit(conversation_id, file_path)

    Logger.info("[AntigravityHooks] tracked #{tool} session=#{conversation_id} path=#{file_path}")
  end

  defp track_edit(_tool, _args, _conversation_id), do: :ok

  defp touch_session(_conn, nil), do: :ok

  defp touch_session(conn, conversation_id) do
    scope = conn.assigns[:current_scope]

    case scope && Sessions.get_by_external_id(scope, conversation_id) do
      nil -> :ok
      session -> Sessions.touch_session(scope, session)
    end
  end

  defp redirect_test_command(conn, "run_command", %{"CommandLine" => command})
       when is_binary(command) do
    scope = conn.assigns[:current_scope]

    # The decision — is this a whole, simple invocation? — belongs to
    # PreToolUseController. This module used to keep its own copy of the regex
    # and its own arg parsing, which meant the pipe-swallowing bug had to be
    # found and fixed twice.
    with %{active_project_id: project_id, cwd: cwd, active_harness_id: harness_id}
         when not is_nil(project_id) and is_binary(cwd) and is_binary(harness_id) <- scope,
         {:ok, task, source, args} <- PreToolUse.classify_test_command(command) do
      curl = build_curl(conn, harness_id, source, args)

      {:deny,
       "CodeMySpec routes `mix #{task}` through its analysis service so runs share " <>
         "one record with the stop-hook validators. Run this command instead " <>
         "(it blocks until the run finishes and prints the results):\n\n#{curl}"}
    else
      _ -> :pass
    end
  end

  defp redirect_test_command(_conn, _tool, _args), do: :pass

  # `cwd` decides there is a disk to run on; the id says which checkout. It used
  # to be `X-Working-Dir: #{cwd}`, which is a path the agent then pastes into a
  # shell command that the server writes results against — wrong once means the
  # wrong disk, silently.
  defp build_curl(conn, harness_id, source, args) do
    payload = Jason.encode!(%{source: source, args: args})

    "curl -sS -X POST http://localhost:#{conn.port}/api/analysis/run " <>
      "-H 'Content-Type: application/json' " <>
      "-H 'X-Harness-Id: #{harness_id}' " <>
      "--data #{shell_quote(payload)}"
  end

  defp shell_quote(string), do: "'" <> String.replace(string, "'", "'\\''") <> "'"
end
