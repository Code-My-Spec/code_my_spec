defmodule CodeMySpec.McpServers.IssuesStoreNoteTest do
  @moduledoc """
  `list_issues` says which store answered.

  Two exist — the hosted server's and a packaged CLI's own database — and
  `register_session` reports the same project id for both, so swapping harness
  mid-session silently changes which one every issue tool talks to. Issues
  resolved earlier come back as `accepted` under different ids, filings from the
  other store are simply absent, and the list looks entirely plausible.

  That last part is the cost. Two of the issues that reappeared as open had
  already been fixed and pushed, and anyone working the list would have
  re-investigated them. Naming the store is not the cure — one store is — but it
  is what makes the wrong one visible.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Issues.IssuesMapper

  defp text(response) do
    response.content
    |> Enum.map(fn
      %{text: t} -> t
      %{"text" => t} -> t
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp listing(issues \\ []), do: text(IssuesMapper.issues_list_response(issues, %{}))

  test "an empty listing still names its store" do
    assert listing() =~ "Store:",
           "an empty list is exactly when you would wonder whether you are asking the " <>
             "right store"
  end

  test "a populated listing names its store" do
    issue = %CodeMySpec.Issues.Issue{
      id: "b323f1c3-ac12-481d-8604-f731c8b722b3",
      title: "a finding",
      severity: :medium,
      status: :incoming
    }

    output = listing([issue])

    assert output =~ "a finding"
    assert output =~ "Store:"
  end

  # The suite compiles against Postgres, which is the server's adapter — so this
  # asserts the server wording. The local branch is the same function on a
  # SQLite build.
  test "against the server it says so, and does not warn about a split" do
    output = listing()

    assert output =~ "Store: the CodeMySpec server."

    refute output =~ "not the server",
           "the warning belongs on the local store, where filings really are invisible " <>
             "to the server"
  end
end
