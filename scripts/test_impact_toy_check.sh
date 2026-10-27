#!/usr/bin/env bash
# Check `mix cms.test_affected` against stock `mix test --stale` on a toy project.
#
#   scripts/test_impact_toy_check.sh [workdir]
#
# Builds a throwaway Mix project (runtime chain, export reference, macro user,
# independent module, @external_resource), runs a green `--stale` baseline, then
# for each diff runs stock `--stale` as ground truth and CodeMySpec.TestImpact
# against the baseline manifests, and compares the two sets of test files.
# Exits 1 on any disagreement.
#
# Two traps this script exists to avoid (both bit the first attempt):
#   * restore with `cp -a`, never `git checkout`: a checkout gives restored files
#     fresh mtimes, which stock --stale then reads as changes;
#   * build the baseline in the directory the scenarios run in: `_build` holds
#     absolute paths, and a moved project recompiles everything.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="${1:-$(mktemp -d)}"
export MIX_ENV=test ELIXIR_ERL_OPTIONS="+fnu"
toy="$work/toy"
snap="$work/snap"
rm -rf "$toy" "$snap"
mkdir -p "$toy"/{lib/code_my_spec,lib/mix/tasks,test,priv,config}
cd "$toy"

cat > mix.exs <<'EOF'
defmodule Toy.MixProject do
  use Mix.Project
  def project, do: [app: :toy, version: "0.1.0", elixir: "~> 1.15", deps: []]
  def application, do: [extra_applications: [:logger]]
end
EOF
echo 'import Config' > config/config.exs
echo hello > priv/data.txt
echo 'defmodule A do def v, do: 1 end' > lib/a.ex
echo 'defmodule B do def v, do: A.v() + 1 end' > lib/b.ex
echo 'defmodule C do def v, do: B.v() + 1 end' > lib/c.ex
echo 'defmodule D do def v, do: 4 end' > lib/d.ex
echo 'defmodule M do defmacro __using__(_), do: quote(do: def(m, do: A.v())) end' > lib/m.ex
printf 'defmodule E do\n  use M\nend\n' > lib/e.ex
printf 'defmodule R do\n  @external_resource "priv/data.txt"\n  def data, do: File.read!("priv/data.txt")\nend\n' > lib/r.ex
for pair in a:A b:B c:C d:D e:E r:R; do
  f="${pair%%:*}"; m="${pair##*:}"
  cat > "test/${f}_test.exs" <<EOF
defmodule ${m}Test do
  use ExUnit.Case
  setup_all do
    IO.puts("RAN test/${f}_test.exs")
    :ok
  end
  test "x", do: assert is_atom(${m})
end
EOF
done
echo 'ExUnit.start()' > test/test_helper.exs
cp "$repo/lib/code_my_spec/test_impact.ex" lib/code_my_spec/
sed '/use Boundary/d' "$repo/lib/mix/tasks/cms.test_affected.ex" > lib/mix/tasks/cms.test_affected.ex
printf '_build\n' > .gitignore
git init -q . && git add -A && git -c user.email=a@b -c user.name=n commit -qm base

mix test --stale 2>&1 | grep -E "tests," || { echo "baseline did not run"; exit 1; }
cp -a "$toy" "$snap"
restore() { cd "$work" && rm -rf "$toy" && cp -a "$snap" "$toy" && cd "$toy"; }

all_tests="test/a_test.exs test/b_test.exs test/c_test.exs test/d_test.exs test/e_test.exs test/r_test.exs"

sc1() { sed -i 's/def v, do: 1/def v, do: 11/' lib/a.ex; }
sc2() { sed -i 's/+ 1/+ 2/' lib/b.ex; }
sc3() { sed -i 's/do: 4/do: 44/' lib/d.ex; }
sc4() { echo '# just a comment' >> lib/a.ex; }
sc5() { echo changed > priv/data.txt; }
sc6() { printf 'defmodule FTest do\n  use ExUnit.Case\n  setup_all do\n    IO.puts("RAN test/f_test.exs")\n    :ok\n  end\n  test "f", do: assert true\nend\n' > test/f_test.exs; }
sc7() { echo '# touch' >> test/c_test.exs; }
sc8() { sed -i 's/A.v()/A.v() + 0/' lib/m.ex; }
sc9() { echo '# cfg' >> config/config.exs; }
sc10() { echo readme > README.md; }
sc11() { git rm -q lib/d.ex test/d_test.exs; }

status=0
for n in 1 2 3 4 5 6 7 8 9 10 11; do
  restore; sleep 1.1; "sc$n"
  stock=$(mix test --stale 2>&1 | { grep -o 'RAN test/[a-z_]*\.exs' || true; } | sed 's/RAN //' | sort | tr '\n' ' ')
  restore; sleep 1.1; "sc$n"
  mine=$(mix cms.test_affected --base HEAD --manifest-dir "$snap/_build/test/lib/toy/.mix" --json 2>/dev/null | tail -1)
  mode=$(echo "$mine" | sed -E 's/.*"mode":"([a-z]+)".*/\1/')
  tests=$(echo "$mine" | { grep -o '"tests":\[[^]]*\]' || true; } | { grep -o 'test/[a-z_]*\.exs' || true; } | sort | tr '\n' ' ')
  if [ "$mode" = all ]; then tests="$all_tests "; fi
  if [ "$stock" = "$tests" ]; then verdict=SAME; else verdict=DIFF; status=1; fi
  echo "sc$n $verdict [$mode] stock: ${stock:-none}| mine: ${tests:-none}"
done
exit $status
