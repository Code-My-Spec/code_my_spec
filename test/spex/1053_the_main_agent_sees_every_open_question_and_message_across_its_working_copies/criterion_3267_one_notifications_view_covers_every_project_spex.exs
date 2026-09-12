defmodule CodeMySpecSpex.Story1053.Criterion3267Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question and message across its
  working copies.
  Criterion 3267 — One notifications view covers every project.

  Rule: the person sees everything waiting on them, in one place.

  The only criterion on this story written against a page rather than a tool,
  and deliberately so. Every other one is about what the *main agent* can see;
  this is the same guarantee for the person the main agent reports to, and they
  do not use MCP tools. Putting it on the tool surface for symmetry would test
  the wrong reader.

  It is also the only one scoped wider than a project. The main agent owns one
  project and its view is bounded by that; a person owns several and is
  interrupted by all of them. A notifications view scoped to "the active
  project" would be correct by the logic of every other surface in this
  codebase, and wrong here — which is why the scenario runs two projects and
  reads without naming either.

  The failure it prevents is quiet: work waiting on a project the person is not
  currently looking at. They would have no reason to look, because nothing tells
  them to.

  ## Green on arrival, and in tension with 3266

  This one passes today, alone among the ten. That is not because it was built
  for — it is because `Notifications.create_question_request/2` keys a question
  to a **user** and nothing narrower, so every question a person owns is
  necessarily in their view.

  Which is the same fact criterion 3266 says has to change: a question must name
  the agent that raised it, its checkout and its project. So the work that
  satisfies 3266 is the work most likely to break this, by giving a question a
  project and then filtering on it.

  Worth stating because a green spex is usually read as ground already held. This
  one is ground held by accident, and the implementer of 3266 should expect to
  keep it green deliberately rather than find it broken afterwards.
  """

  use CodeMySpecSpex.Case

  # A person's notifications are a cloud-app surface. The case defaults to the
  # local app, where `live/2` answers 404 from inside LiveViewTest.
  @endpoint CodeMySpecWeb.Endpoint

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One place shows everything waiting on a person" do
    scenario "questions are open on two of the person's projects" do
      given_ "an open question on each of two projects the person owns", context do
        # A distinct name, because a second project defaults to "some name" and
        # the lookups that resolve a project by name then answer ambiguously
        # rather than wrongly — which surfaces as MultipleResultsError from
        # inside a plug, several layers from the fixture that caused it.
        other =
          CodeMySpecSpex.Fixtures.project_fixture(context.scope, %{
            name: "the-other-project-#{System.unique_integer([:positive])}"
          })

        here =
          CodeMySpecSpex.Fixtures.ask_question(context.scope.user.id,
            title: "waiting on the first project",
            questions: [
              %{
                "question" => "Which way on the first project?",
                "options" => [%{"label" => "A"}, %{"label" => "B"}]
              }
            ]
          )

        there =
          CodeMySpecSpex.Fixtures.ask_question(context.scope.user.id,
            title: "waiting on the second project",
            questions: [
              %{
                "question" => "Which way on the second project?",
                "options" => [%{"label" => "A"}, %{"label" => "B"}]
              }
            ]
          )

        {:ok,
         context
         |> Map.put(:other, other)
         |> Map.put(:here, here)
         |> Map.put(:there, there)}
      end

      when_ "the person opens their notifications", context do
        # Not scoped to a project in the path, which is the criterion: they do
        # not have to say which project they are asking about, because the
        # answer is all of them.
        {:ok, _live, html} = live(context.conn, "/app/notifications")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "questions from both projects are listed", context do
        assert context.html =~ "Which way on the first project?",
               "the first project's question is missing from the notifications view"

        assert context.html =~ "Which way on the second project?",
               """
               The second project's question is missing from the notifications
               view.

               A view scoped to the active project is correct by the logic of
               nearly every other surface here and wrong for this one. A person
               owns several projects and is interrupted by all of them, so work
               waiting on the project they are not currently looking at waits
               silently — they have no reason to look, because nothing told
               them to.
               """

        {:ok, context}
      end
    end
  end
end
