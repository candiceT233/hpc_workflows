#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def run(cmd: list[str], cwd: Path, log_path: Path, check: bool = True) -> subprocess.CompletedProcess:
    with log_path.open("a", encoding="utf-8") as log:
        log.write("+ " + " ".join(cmd) + "\n")
        log.flush()
        proc = subprocess.run(cmd, cwd=cwd, text=True, stdout=log, stderr=subprocess.STDOUT)
        log.write(f"[exit {proc.returncode}]\n")
    if check and proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd)
    return proc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run 1000genome-workflow through native Pegasus Shell codegen")
    parser.add_argument("--repo", default="repos/1000genome-workflow")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--dir-name", default=None)
    parser.add_argument("--individuals-jobs", type=int, default=1)
    parser.add_argument("--datafile", default="data.csv")
    parser.add_argument("--dataset", default="20130502")
    parser.add_argument("--plan-only", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    root = Path.cwd().resolve()
    repo = (root / args.repo).resolve()
    run_dir = Path(args.run_dir).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    log_path = run_dir / "pegasus-1000genome.log"

    if not repo.exists():
        raise SystemExit(f"1000genome repo missing: {repo}")

    sys.path.insert(0, str(repo))
    from daxgen import GenomeWorkflow  # type: ignore

    dir_name = args.dir_name or f"codex-shell-{int(time.time())}"
    os.chdir(repo)

    workflow = GenomeWorkflow(
        datafile=args.datafile,
        dataset=args.dataset,
        ind_jobs=args.individuals_jobs,
        exec_site="local",
        use_bash=False,
        src_path=str(repo),
    )
    workflow.create_sites_catalog()
    workflow.create_pegasus_properties()
    workflow.props["pegasus.catalog.site"] = "YAML"
    workflow.props["pegasus.catalog.site.file"] = "sites.yml"
    workflow.props["pegasus.catalog.transformation"] = "YAML"
    workflow.props["pegasus.catalog.transformation.file"] = "transformations.yml"
    workflow.props["pegasus.catalog.replica"] = "YAML"
    workflow.props["pegasus.catalog.replica.file"] = "replicas.yml"
    workflow.props["pegasus.data.configuration"] = "sharedfs"
    workflow.props["pegasus.code.generator"] = "Shell"
    workflow.props["pegasus.dir.useTimestamp"] = "false"
    workflow.props["pegasus.dir.storage.deep"] = "false"
    workflow.create_transformation_catalog()
    workflow.create_replica_catalog()
    workflow.create_workflow()
    workflow.write(produce_dot=False)
    workflow.run(dir_name, submit=False, wait=False)

    submit_dir = repo / dir_name
    if not submit_dir.exists():
        raise RuntimeError(f"Pegasus submit directory not created: {submit_dir}")

    shell_scripts = sorted(
        path for path in submit_dir.glob("*.sh") if path.name != "pegasus-lite-common.sh"
    )
    if len(shell_scripts) != 1:
        raise RuntimeError(f"Expected one Pegasus shell workflow script in {submit_dir}, found {shell_scripts}")

    if not args.plan_only:
        run(["bash", str(shell_scripts[0])], submit_dir, log_path)
        jobstate = submit_dir / "jobstate.log"
        if not jobstate.exists() or "SHELL_SCRIPT_FINISHED 0" not in jobstate.read_text(errors="replace"):
            raise RuntimeError(f"Pegasus shell workflow did not report success in {jobstate}")

    output_dir = Path(workflow.local_storage_dir)
    expected_outputs = 10 * len(workflow.populations) * 2
    outputs = sorted(output_dir.glob("*.tar.gz"))
    if not args.plan_only:
        non_empty = [path for path in outputs if path.stat().st_size > 0]
        if len(non_empty) < expected_outputs:
            raise RuntimeError(
                f"Expected at least {expected_outputs} non-empty staged outputs in {output_dir}, found {len(non_empty)}"
            )

    manifest = {
        "engine": "pegasus-shell",
        "repo": str(repo),
        "submit_dir": str(submit_dir),
        "workflow_id": workflow.wid,
        "output_dir": str(output_dir),
        "expected_outputs": expected_outputs,
        "current_outputs": len(outputs),
        "individuals_jobs": args.individuals_jobs,
        "plan_only": args.plan_only,
    }
    (run_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
