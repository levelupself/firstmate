# ast-grep structural-search trial

This record captures the 2026-08-06 trial that informed whether ast-grep should appear in crewmate briefs.
The trial used ast-grep 0.45.0 on Linux x86_64 in the Firstmate repository at commit `9cfa802`.
It compares the structural tool with GNU grep 3.8 on three routine but different search tasks.

## Measurement method

Ground truth was established by reading every textual hit and the surrounding syntax before classifying it.
Correctness is reported as true results found over total true results, followed by the number of false positives.
Returned tokens are whitespace-delimited output tokens, computed by summing `awk`'s `NF` over the exact command output.
This deliberately reproducible lexical count is a context-volume proxy, not a model-specific tokenizer count.
Time is the median wall-clock duration of 25 warm runs after five discarded warmups, measured with `date +%s%N` and output redirected to `/dev/null`.

The grep commands were:

```sh
grep -RIn --include='*.sh' resolve_directory_input bin tests
grep -RIn --include='*.sh' fm_backend_agent_state bin tests
grep -nE '^[[:space:]]*except([[:space:]]|[(]|$)' bin/backends/herdr-workspace-move.py
```

The ast-grep commands were:

```sh
ast-grep run -p 'resolve_directory_input $$$ARGS' --selector command -l bash bin tests --color never --heading never
ast-grep run -p 'fm_backend_agent_state $$$ARGS' --selector command -l bash bin tests --color never --heading never
ast-grep run -k except_clause -l python bin/backends/herdr-workspace-move.py --color never --heading never
```

The count command appended this pipeline to each search command:

```sh
awk '{ bytes += length($0) + 1; words += NF; lines += 1 } END { printf "lines=%d lexical_tokens=%d bytes=%d\n", lines, words, bytes }'
```

## Results

| Task | Hand-established ground truth | grep correctness | ast-grep correctness | grep tokens | ast-grep tokens | grep median | ast-grep median |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Find every direct caller of `resolve_directory_input` | Six calls at `bin/fm-spawn.sh:160,162,165` and `bin/fm-brief.sh:92,94,99` after this branch's scaffold edit | 6/6, 2 false positives | 6/6, 0 false positives | 44 | 40 | 5.971 ms | 74.160 ms |
| Isolate live parse-level calls to `fm_backend_agent_state` | Three calls at `bin/fm-backend.sh:934`, `bin/fm-bootstrap.sh:465`, and `tests/fm-backend-tmux-smoke.test.sh:165` | 3/3, 20 false positives | 3/3, 0 false positives | 210 | 16 | 5.791 ms | 68.568 ms |
| Locate Python `except_clause` structures | Six clauses at `bin/backends/herdr-workspace-move.py:46,66,75,87,95,113` | 6/6, 0 false positives | 6/6, 0 false positives | 20 | 37 | 2.434 ms | 4.821 ms |

The first grep result set also included the two function definitions.
The second grep result set included eight comments, one definition, ten shell snippets embedded in strings, and one assertion message in addition to the three live calls.
The ast-grep output for the Python structure query included clause bodies, which made it larger than grep's header-only result even though both were correct.
The structural searches were 12 to 13 times slower than grep on the repository-wide shell tasks, but their absolute warm medians stayed below 75 ms.

## Wrong-pattern probes

A C-style Bash call pattern that looks plausible to someone transferring syntax from another language silently returned no matches:

```console
$ ast-grep run -p 'resolve_directory_input($$$ARGS)' -l bash bin tests
$ echo $?
1
```

A malformed Bash control-flow pattern printed a warning and no matches but exited successfully:

```console
$ ast-grep run -p 'if $COND; then $$$BODY fi' -l bash bin/fm-bootstrap.sh
Warning: Pattern contains an ERROR node and may cause unexpected results.
Help: ast-grep parsed the pattern but it matched nothing in this run. Try using playground to refine the pattern.
$ echo $?
0
```

An incomplete Python pattern was accepted without warning and matched all six full clauses, including tuple exception types and their bodies:

```console
$ ast-grep run -p 'except $ERR:' -l python bin/backends/herdr-workspace-move.py --color never --heading never
# 12 output lines covering all six clauses
$ echo $?
0
```

The important failure mode is therefore not a crash.
A wrong pattern can look like a clean empty result, a warning with success status, or a broader match than the pattern author expected.
An unfamiliar structural query needs a small hand-checked sample or a text-search baseline before its absence or completeness is trusted.

## Recommendation

Teach ast-grep to crewmates in the brief scaffold as an optional structural layer, while retaining `rg` as the baseline and explicitly requiring unfamiliar patterns to be hand-checked.
The caller tasks removed all false positives and cut the noisy task from 210 returned lexical tokens to 16, while the absolute latency remained interactive.
The Python task proves that structural output is not automatically smaller, and the wrong-pattern probes rule out making ast-grep mandatory or treating a zero-result exit status as authoritative.
This is a bounded adoption recommendation, not a mandate: bootstrap remains non-blocking when ast-grep is absent, and briefs direct workers to use it only where text search over-matches.

## Installation verification

The repository installer selected the official `app-x86_64-unknown-linux-gnu.zip` release asset, verified SHA-256 `78931ae35ebac33d9a72b3aecea3e3d62d6e5b0b718ac8bbedfbe69d68421e41`, extracted only `ast-grep`, and installed it at `/home/fungiman/.local/bin/ast-grep`.
No `sg` alias was installed.

```console
$ command -v ast-grep
/home/fungiman/.local/bin/ast-grep
$ ast-grep --version
ast-grep 0.45.0
$ command -v sg
/usr/bin/sg
$ dpkg-query -S /usr/bin/sg
login: /usr/bin/sg
$ sha256sum /usr/bin/sg
572ab15948df3969e929b902641c3a42e76dce7d71a22fbc58011ca89d8d965e  /usr/bin/sg
```

The `/usr/bin/sg` checksum was identical before and after installation.
Nothing else was installed.
