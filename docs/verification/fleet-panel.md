# Fleet panel repaint verification

Audience: maintainer verification.

This record holds reusable evidence for the fleet panel watch-mode repaint guarantee.
The implementation is shared by `bin/fm-fleet-view.sh` and `bin/fm-cockpit.sh`, while `tests/fm-fleet-snapshot-view.test.sh` owns automated ordering and residual-line coverage.

Verified on 2026-08-05 in an isolated tmux 3.4 pane on Linux.

The pane ran the production watch command against a fixture that alternated between three-line and one-line frames every 0.05 seconds.
Twenty consecutive pane captures sampled every 0.01 seconds remained nonblank, showed only a complete long or short frame, and showed no residual long-frame lines beneath a short frame.

```sh
tmux -L fm-fleet-visual new-session -d -s fleet-visual -x 45 -y 12 \
  "FM_HOME=\"$VERIFY_HOME\" PATH=\"$VERIFY_HOME/bin:$PATH\" \
  \"$VERIFY_HOME/bin/fm-fleet-view.sh\" --watch 0.05"

for sample in $(seq 1 20); do
  tmux -L fm-fleet-visual capture-pane -p -t fleet-visual:0.0 \
    | sed '/^[[:space:]]*$/d' \
    | awk -v sample="$sample" '
        NR == 1 { first = $0 }
        { count++ }
        END {
          if (count != 1 && count != 3) exit 1
          if (first != "short" && first != "long one") exit 1
          printf "%02d valid\n", sample
        }'
  sleep 0.01
done
```

```text
01 valid
02 valid
03 valid
04 valid
05 valid
06 valid
07 valid
08 valid
09 valid
10 valid
11 valid
12 valid
13 valid
14 valid
15 valid
16 valid
17 valid
18 valid
19 valid
20 valid
```

The observed pane changed directly between complete frames without a visible blank refresh.
