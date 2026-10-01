defmodule CodeMySpecWeb.WidgetIssueNotice do
  @moduledoc """
  Tells the project's main agent about an issue filed from the widget, by id.

  6da8e0e5: an issue John filed from the widget, and asked main to fix, never
  reached it. `list_issues` truncated 547 issues to the first ~150 by severity,
  and the new medium one was not among them; main reported that nothing had
  landed. Filed here, both widget paths name it to main directly.

  Here rather than in `Issues`, which sits below `Agents` and cannot call up.
  """

  alias CodeMySpec.Agents
  alias CodeMySpec.Users.Scope

  @spec send(String.t(), String.t(), map()) :: :ok
  def send(account_id, project_id, issue) do
    scope = %Scope{active_account_id: account_id, active_project_id: project_id}

    Agents.notify_main(
      scope,
      :issue_filed,
      "An issue was filed from the widget: \"#{issue.title}\" (#{issue.severity}), " <>
        "id #{issue.id}. `get_issue` with that id reads it."
    )
  end
end
