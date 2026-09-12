# Print the wake fixture's deploy key, for onboarding its checkout.
#
# Usage: mix cms.seed priv/repo/qa_wake_key.exs
#
# `deploy_key` is Cloak-encrypted at rest, so reading the column with psql
# returns ciphertext — `\x010a4145…` — which `cms.harness.onboard` then rejects
# as no credential at all. That failure reads as "this project has no key" and
# sends you to generate one it already has.
#
# Separate from the seed because a seed's output belongs in a transcript and a
# credential does not. This exists to be piped:
#
#     CMS_DEPLOY_KEY=$(mix cms.seed priv/repo/qa_wake_key.exs | tail -1) \
#       mix cms.harness.onboard <path> --project <id>

import Ecto.Query

alias CodeMySpec.Projects.Project
alias CodeMySpec.Repo

case Repo.one(from p in Project, where: p.name == "Math Test Project", select: p.deploy_key) do
  nil ->
    IO.puts(:stderr, "No Math Test Project. Run priv/repo/qa_wake_seed.exs first.")
    System.halt(1)

  "" ->
    IO.puts(:stderr, "Math Test Project has no deploy key. The seed calls ensure_deploy_key/2.")
    System.halt(1)

  key ->
    IO.puts(key)
end
