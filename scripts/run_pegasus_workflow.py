#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

from Pegasus.api import (
    Arch,
    Directory,
    File,
    FileServer,
    Job,
    Operation,
    OS,
    Properties,
    ReplicaCatalog,
    Site,
    SiteCatalog,
    Transformation,
    TransformationCatalog,
    TransformationSite,
    Workflow,
)


def run(cmd: list[str], cwd: Path, log_path: Path, check: bool = True) -> subprocess.CompletedProcess:
    with log_path.open("a") as log:
        log.write("+ " + " ".join(cmd) + "\n")
        log.flush()
        proc = subprocess.run(cmd, cwd=cwd, text=True, stdout=log, stderr=subprocess.STDOUT)
        log.write(f"[exit {proc.returncode}]\n")
    if check and proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd)
    return proc


def main() -> None:
    parser = argparse.ArgumentParser(description="Native Pegasus fanout workflow")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--jobs", type=int, default=32)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument(
        "--engine",
        choices=("condor", "shell"),
        default="condor",
        help="Pegasus execution backend. 'shell' uses the Pegasus Shell code generator and does not require HTCondor.",
    )
    args = parser.parse_args()

    run_dir = Path(args.run_dir).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    os.chdir(run_dir)

    log_path = run_dir / "pegasus-driver.log"
    work_dir = run_dir / "work"
    outputs_dir = run_dir / "outputs"
    scratch_dir = run_dir / "scratch"
    submit_dir = work_dir / "submit"
    outputs_dir.mkdir(exist_ok=True)
    scratch_dir.mkdir(exist_ok=True)

    pegasus_keg = shutil.which("pegasus-keg")
    if not pegasus_keg:
        raise RuntimeError("pegasus-keg not found on PATH")
    transformation_pfn = os.environ.get("PEGASUS_TRANSFORMATION_PFN", pegasus_keg)
    if not Path(transformation_pfn).exists():
        raise RuntimeError(f"Pegasus transformation executable not found: {transformation_pfn}")

    input_file = run_dir / "input.txt"
    input_file.write_text(("Pegasus native workflow input\n" * 4096))

    props = Properties()
    props["pegasus.catalog.site"] = "YAML"
    props["pegasus.catalog.site.file"] = "sites.yml"
    props["pegasus.catalog.transformation"] = "YAML"
    props["pegasus.catalog.transformation.file"] = "transformations.yml"
    props["pegasus.catalog.replica"] = "YAML"
    props["pegasus.catalog.replica.file"] = "replicas.yml"
    props["pegasus.data.configuration"] = "sharedfs" if args.engine == "shell" else "condorio"
    props["pegasus.dir.useTimestamp"] = "false"
    props["pegasus.dir.storage.deep"] = "false"
    if args.engine == "shell":
        props["pegasus.code.generator"] = "Shell"
    props.write("pegasus.properties")

    local = Site("local", arch=Arch.X86_64, os_type=OS.LINUX).add_directories(
        Directory(Directory.SHARED_SCRATCH, scratch_dir).add_file_servers(
            FileServer("file://" + str(scratch_dir), Operation.ALL)
        ),
        Directory(Directory.LOCAL_STORAGE, outputs_dir).add_file_servers(
            FileServer("file://" + str(outputs_dir), Operation.ALL)
        ),
    )

    if args.engine == "condor":
        execution_site = "condorpool"
        condorpool = (
            Site("condorpool", arch=Arch.X86_64, os_type=OS.LINUX)
            .add_directories(
                Directory(Directory.LOCAL_STORAGE, outputs_dir).add_file_servers(
                    FileServer("file://" + str(outputs_dir), Operation.ALL)
                )
            )
            .add_pegasus_profile(style="condor")
            .add_condor_profile(universe="local")
        )
        SiteCatalog().add_sites(local, condorpool).write("sites.yml")
    else:
        execution_site = "local"
        SiteCatalog().add_sites(local).write("sites.yml")

    source = File("input.txt")
    ReplicaCatalog().add_replica("local", source, input_file).write("replicas.yml")

    process = Transformation("process").add_sites(
        TransformationSite(execution_site, transformation_pfn, is_stageable=False, arch=Arch.X86_64, os_type=OS.LINUX)
    )
    merge = Transformation("merge").add_sites(
        TransformationSite(execution_site, pegasus_keg, is_stageable=False, arch=Arch.X86_64, os_type=OS.LINUX)
    )
    TransformationCatalog().add_transformations(process, merge).write("transformations.yml")

    workflow = Workflow("pegasus-fanout")
    intermediates = []
    for index in range(args.jobs):
        out = File(f"part-{index:04d}.txt")
        job = (
            Job(process)
            .add_args("-a", f"process-{index}", "-T1", "-i", source, "-o", out)
            .add_inputs(source)
            .add_outputs(out, register_replica=True)
        )
        workflow.add_jobs(job)
        intermediates.append((job, out))

    final = File("final.txt")
    merge_job = Job(merge).add_args("-a", "merge", "-T1")
    for _, out in intermediates:
        merge_job.add_args("-i", out)
        merge_job.add_inputs(out)
    merge_job.add_args("-o", final).add_outputs(final, register_replica=True)
    workflow.add_jobs(merge_job)
    for job, _ in intermediates:
        workflow.add_dependency(job, children=[merge_job])

    workflow.add_replica_catalog(ReplicaCatalog())
    workflow.add_transformation_catalog(TransformationCatalog())

    workflow.plan(
        conf="pegasus.properties",
        sites=[execution_site],
        output_sites=["local"],
        dir=work_dir,
        relative_dir="submit",
        cluster=["horizontal"],
        force=True,
        submit=False,
    )

    if not submit_dir.exists():
        raise RuntimeError(f"Expected submit dir was not created: {submit_dir}")

    if args.engine == "condor":
        run(["pegasus-run", str(submit_dir)], run_dir, log_path)

        deadline = time.time() + args.timeout
        final_status = ""
        while time.time() < deadline:
            run(["pegasus-status", "-l", str(submit_dir)], run_dir, log_path, check=False)
            status_text = log_path.read_text(errors="replace")
            if "Success" in status_text or "succeeded" in status_text.lower():
                final_status = "success"
                break
            if "Failure" in status_text or "failed" in status_text.lower():
                final_status = "failure"
                break
            time.sleep(10)

        if final_status != "success":
            run(["pegasus-analyzer", str(submit_dir)], run_dir, log_path, check=False)
            raise RuntimeError(f"Pegasus workflow did not reach success, final_status={final_status or 'timeout'}")
    else:
        shell_scripts = sorted(
            path for path in submit_dir.glob("*.sh") if path.name != "pegasus-lite-common.sh"
        )
        if len(shell_scripts) != 1:
            raise RuntimeError(f"Expected one Pegasus shell workflow script, found {shell_scripts}")
        run(["bash", str(shell_scripts[0])], submit_dir, log_path)
        jobstate = submit_dir / "jobstate.log"
        if not jobstate.exists() or "SHELL_SCRIPT_FINISHED 0" not in jobstate.read_text(errors="replace"):
            raise RuntimeError(f"Pegasus shell workflow did not report success in {jobstate}")

    final_output = outputs_dir / "final.txt"
    if not final_output.exists() or final_output.stat().st_size == 0:
        raise RuntimeError(f"Expected final Pegasus output missing or empty: {final_output}")

    manifest = {
        "jobs": args.jobs,
        "engine": args.engine,
        "process_transformation": transformation_pfn,
        "submit_dir": str(submit_dir),
        "final_output": str(final_output),
        "final_output_bytes": final_output.stat().st_size,
    }
    (run_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True))
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
