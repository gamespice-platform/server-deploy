# GitHub quota tools

The shared GitHub token (`core`'s `gh`) has 5000 REST calls per hour. A drained quota in the middle of a release chain fails the chain halfway. These tools turn it into a known pause. `rate_limit` is free, so none of this costs quota.

## tools/gh-quota.sh

| Command | Behaviour |
| --- | --- |
| `gh-quota.sh status` | prints `remaining`, `limit`, `reset` (epoch), reset time and seconds left |
| `gh-quota.sh need N` | exit 0 if `remaining >= N + 300`; otherwise prints the reset time and exits 75 |
| `gh-quota.sh wait N` | sleeps in chunks of at most 60 s, never past the reset, until the quota covers N; exit 75 if still short after the reset |

The reserve (300) is `GH_QUOTA_RESERVE`. Exit 2 means the `rate_limit` call itself failed. Release scripts call `need` (or `wait`) before heavy GitHub steps.

## tools/gh-quota-sampler.sh

Appends one line per run to `~/.fleet/gh-quota.log`, at most once a minute:

```
2026-11-23T04:40:01-05:00 remaining=4210 delta=-48 reset=1795428063 procs=[core:123:gh api ...; gamedev:456:git fetch ...]
```

`delta` is the change since the last sample (`n/a` first run, `reset` across a window reset). `procs` lists every user's processes matching `gh`, `curl.*github`, `check-ci`, `addons-lock`, `ls-remote`, `git fetch|ls-remote|clone`. A drop with an empty `procs` list means the calls came from a process too short to catch, or from outside this machine.

Crontab line for gamedev (every minute):

```
* * * * * /home/gamedev/godot/gs-server-deploy/tools/gh-quota-sampler.sh
```

Tests: `tools/check_gh_quota.sh` (stubbed, no GitHub calls).
