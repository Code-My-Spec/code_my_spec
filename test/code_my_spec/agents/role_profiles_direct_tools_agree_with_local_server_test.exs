defmodule CodeMySpec.Agents.RoleProfilesDirectToolsAgreeWithLocalServerTest do
  @moduledoc """
  Issue `7507da80`: `RoleProfile`'s per-role `tools` lists drifted from
  `LocalServer`'s actual registrations -- `ask_user_question`,
  `check_answer` and `list_user_questions` were listed for both `coding`
  and `qa`, `tap_out` and `cancel_task` were not, even though `LocalServer`
  grants all five role-independently (`@spine ++ @unscriptable`; a direct
  call is never gated on `RoleProfile` at all, confirmed in
  `CodeMySpec.McpServers.LibraryTools.call/4`).

  Scoped to exactly these five names and to `coding`/`qa` -- the two roles
  and the tools this issue and its precedent (`e809c0db`) are about.
  `promote` and `start_analysis` are deliberately asymmetric between the two
  roles already (coding carries `promote`, qa carries `start_analysis`, not
  the reverse) -- a separate, standing design choice this test must not
  treat as drift.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.McpServers.LocalServer

  @roles [:coding, :qa]
  @direct_tools ["ask_user_question", "check_answer", "list_user_questions", "tap_out", "cancel_task"]

  test "LocalServer still registers every tool this manifest treats as universal" do
    names = LocalServer.registrations() |> Enum.map(& &1.name)
    missing = Enum.reject(@direct_tools, &(&1 in names))

    assert missing == [],
           "LocalServer no longer registers #{inspect(missing)}, which RoleProfile treats as universal"
  end

  test "coding and qa both carry every tool LocalServer grants role-independently" do
    missing =
      for role <- @roles,
          name <- @direct_tools,
          not RoleProfile.carries?(role, name),
          do: {role, name}

    assert missing == [],
           """
           LocalServer grants these tools to every role; RoleProfile's own
           manifest disagrees for some of them, which is exactly the drift
           7507da80 was filed against:

           #{Enum.map_join(missing, "\n", fn {role, name} -> "  #{role}: #{name}" end)}
           """
  end
end
