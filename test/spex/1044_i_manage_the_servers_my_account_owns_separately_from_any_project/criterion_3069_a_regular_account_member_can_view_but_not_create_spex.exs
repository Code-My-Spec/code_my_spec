defmodule CodeMySpecSpex.Story1044.Criterion3069Spex do
  @moduledoc """
  Story 1044 — I manage the servers my account owns, separately from any project
  Criterion 3069 — A regular account member can view but not create.

  No role check exists on `ServerLive.Index` today — every member sees the
  same provisioning controls as the owner. This spec drives a plain
  `:member`-role user and asserts the future contract, so it fails for the
  true reason (nothing restricts creation by role yet) rather than one
  invented to pass today.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A plain member of the account can see servers but not create one" do
    scenario "the provisioning controls are absent for a non-owner, non-admin member" do
      given_ "a second user who is only a plain member of this account", context do
        member_user = CodeMySpecSpex.Fixtures.user_fixture()
        CodeMySpecSpex.Fixtures.member_fixture(member_user, context.account, :member)

        member_conn =
          Phoenix.ConnTest.build_conn()
          |> log_in_user(member_user)

        {:ok, Map.put(context, :member_conn, member_conn)}
      end

      when_ "that member visits the account-level servers page", context do
        {:ok, servers_live, html} = live(context.member_conn, "/app/servers")
        {:ok, context |> Map.put(:servers_live, servers_live) |> Map.put(:html, html)}
      end

      then_ "the page renders for them, but nothing on it can create a server", context do
        refute has_element?(context.servers_live, "[data-test='provision-form']"),
               "a plain member should not see the provisioning form at all"

        refute has_element?(context.servers_live, "[data-test='link-server']"),
               "a plain member should not be able to link a server into the account either"

        assert context.html =~ "Servers",
               "the page itself should still render for a member — this is a view " <>
                 "restriction on actions, not on visibility"

        {:ok, context}
      end
    end
  end
end
