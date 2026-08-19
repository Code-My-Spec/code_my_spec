# QA seed for story 727, criterion 739 — "the operator picks which agent's
# state to look at".
#
# Why this exists. Four QA attempts scored 739 partial with the same reason:
# the harness picker renders on `/app/projects/:id/files` and
# `/app/projects/:id/problems`, those pages are on the real CodeMySpec project,
# and the QA user does not own it — the page answers "No projects yet." Every
# attempt then fell back to grepping `files_live.ex` for `<.harness_picker>`,
# which proves the component is wired and proves nothing about picking.
#
# John's response to that, verbatim: "yall better write a seed then or use an
# existing one. This is the stupidest fucking reason for you to be blocking qa."
# He is right. A picker needs two things to pick between, and nothing was
# stopping us from creating them.
#
# What it adds. `qa_seeds.exs` already creates the QA user and the QA Fixture
# Project they can see; this gives that project **two harnesses with files**, so
# the picker has a real choice to render and switching it changes what the page
# shows. Distinct file counts on purpose — a picker that silently ignored the
# selection would show the same number either way, and equal counts would hide
# that.
#
# Idempotent: `Harnesses.issue/3` touches an existing row rather than minting a
# second, and files upsert on [project_id, harness_id, path].
#
# Run through `mix cms.seed`, which starts the database and nothing else. Plain
# `mix run` boots the endpoint and dies `:eaddrinuse` against the dev server on
# :4000 — a failure that mentions neither seeds nor ports.
#
#   mix cms.seed priv/repo/qa_seeds.exs        # user, account, project
#   mix cms.seed priv/repo/qa_739_seed.exs     # this

import Ecto.Query

alias CodeMySpec.Files
alias CodeMySpec.Harnesses
alias CodeMySpec.Repo
alias CodeMySpec.Users.Scope

project_id = "11111111-1111-4111-8111-111111111111"

project =
  Repo.one(from p in "projects", where: p.id == type(^project_id, :binary_id), select: %{id: p.id})

if is_nil(project) do
  raise """
  QA Fixture Project #{project_id} does not exist.

  Run `mix cms.seed priv/repo/qa_seeds.exs` first — it creates the user, the account
  membership and the project this seed hangs harnesses off.
  """
end

scope = %Scope{active_project_id: project_id}

# Two checkouts of one project, which is the shape story 727 is about: the same
# project seen from two working copies, each with its own file state.
copies = [
  {"qa-739-alpha", "/tmp/qa739/alpha", 3},
  {"qa-739-beta", "/tmp/qa739/beta", 5}
]

results =
  Enum.map(copies, fn {label, root, file_count} ->
    {:ok, harness} = Harnesses.issue(scope, nil, label: label)
    {:ok, harness} = Harnesses.report_root(harness, root)

    harness_scope = %Scope{scope | active_harness_id: harness.id}

    files =
      for i <- 1..file_count do
        %{
          path: "lib/qa739/#{label}_module_#{i}.ex",
          role: :implementation,
          mtime: DateTime.utc_now(),
          size: 100 + i,
          fingerprint: "qa739-#{label}-#{i}",
          component_id: nil,
          story_id: nil,
          valid: true,
          validation_errors: nil
        }
      end

    {count, _} = Files.upsert_files(harness_scope, files)
    {label, harness.id, root, count}
  end)

IO.puts("""

QA seed for story 727 / criterion 739 — harness picker
======================================================

Project: QA Fixture Project (#{project_id})

Harnesses on it:
#{Enum.map_join(results, "\n", fn {label, id, root, count} -> "  #{label}  #{id}\n    root:  #{root}\n    files: #{count}" end)}

The counts differ deliberately. On
`/app/projects/#{project_id}/files` the picker should offer both, and
switching between them should change the file list — same number either way
means the selection is not reaching the query.

Log in as the QA user first (see `qa_seeds.exs` output for the passwordless
procedure): /users/log-in, then /dev/mailbox for the link, rewriting the origin
to http://127.0.0.1:4000.

Cleanup, when the criterion is done — the harnesses are real rows on a real
project and there is no reason to keep them:

    mix run -e 'import Ecto.Query; alias CodeMySpec.Repo
      ids = Repo.all(from h in "harnesses", where: like(h.label, "qa-739-%"), select: h.id)
      Repo.delete_all(from f in "files", where: f.harness_id in ^ids)
      Repo.delete_all(from h in "harnesses", where: h.id in ^ids)'
""")
