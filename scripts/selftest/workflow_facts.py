"""Read facts out of a workflow file for scripts/selftest/workflows.sh, on the shared YAML loader.

The self-tests used to cut jobs out with `sed` ranges, which depended on job order and
indentation. This reads the parsed document, so a job is found by its id and a mutation is a
change to the parsed job, not to text.

Usage: python -I scripts/selftest/workflow_facts.py <command> <workflow file> [args]
  jobs                      job ids, one per line
  job <id>                  the job as JSON
  top                       the document without `jobs`, as JSON
  on                        the trigger names, one per line
  options <input>           the options of a workflow_dispatch choice input, one per line
  step-run <id> <fragment>  the `run:` text of the steps of a job named with the fragment
  group <id>                the concurrency group of a job
  merge <id> <json>         the job with the JSON fragment merged in (mappings merge, lists
                            extend), as JSON
Exit codes: 0 ok, 1 not found, 2 usage error.
"""

import json
import os
import sys
from pathlib import Path
from typing import Any

# `python -I` leaves the script directory off sys.path; the loader sits in scripts/guard.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "guard"))
from workflow_yaml import load_workflow  # noqa: E402  (import after the path setup above)


def _merge(base: Any, extra: Any) -> Any:
    if isinstance(base, dict) and isinstance(extra, dict):
        merged = dict(base)
        for key, value in extra.items():
            merged[key] = _merge(base[key], value) if key in base else value
        return merged
    if isinstance(base, list) and isinstance(extra, list):
        return base + extra
    return extra


def _job(document: Any, job_id: str) -> Any:
    jobs = document.get("jobs") if isinstance(document, dict) else None
    if not isinstance(jobs, dict) or job_id not in jobs:
        raise KeyError(f"no job '{job_id}'")
    return jobs[job_id]


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    command, path, args = argv[0], Path(argv[1]), argv[2:]
    document = load_workflow(path.read_text(encoding="utf-8"))
    try:
        if command == "jobs" and not args:
            print("\n".join(document["jobs"]))
        elif command == "job" and len(args) == 1:
            print(json.dumps(_job(document, args[0])))
        elif command == "top" and not args:
            print(json.dumps({k: v for k, v in document.items() if k != "jobs"}))
        elif command == "on" and not args:
            on = document.get("on", document.get(True))
            print("\n".join([on] if isinstance(on, str) else list(on)))
        elif command == "options" and len(args) == 1:
            on = document.get("on", document.get(True))
            print("\n".join(str(o) for o in on["workflow_dispatch"]["inputs"][args[0]]["options"]))
        elif command == "step-run" and len(args) == 2:
            steps = _job(document, args[0]).get("steps", [])
            print(
                "\n".join(str(s.get("run", "")) for s in steps if args[1] in str(s.get("name", "")))
            )
        elif command == "group" and len(args) == 1:
            concurrency = _job(document, args[0]).get("concurrency")
            print(concurrency["group"] if isinstance(concurrency, dict) else concurrency)
        elif command == "merge" and len(args) == 2:
            print(json.dumps(_merge(_job(document, args[0]), json.loads(args[1]))))
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except (KeyError, TypeError) as e:
        print(f"not found: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
