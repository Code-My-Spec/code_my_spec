defmodule CmsHarnessTest do
  @moduledoc false
  # `CodeMySpec.TempFile` is a leaf boundary with no deps of its own, taken for
  # temp paths that two concurrently running suites cannot both pick. It is the
  # one thing here reaching outside the harness; when the harness moves to its
  # own repo this module goes with it, and a dozen lines of token generation
  # come along rather than the dependency.
  # `Machine` and `HeldProvider` are the only things spex may reach: they drive
  # a real harness through them rather than referencing `CmsHarness` themselves,
  # which they may not do. Everything else here stays internal to the harness's
  # own tests.
  #
  # `HeldProvider` is exported for the same reason `Machine` is. An agent
  # mid-turn is a premise three of story 1024's criteria share, and there is no
  # way to establish it except by holding a provider's response — so a criterion
  # has to be able to say when to hold and when to let go.
  use Boundary,
    top_level?: true,
    deps: [CmsHarness, CodeMySpec.TempFile],
    exports: [Machine, HeldProvider]
end
