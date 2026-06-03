#!/usr/bin/env python3
"""Run the biobb_wf_md_setup tutorial workflow non-interactively."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from biobb_analysis.gromacs.gmx_energy import gmx_energy
from biobb_analysis.gromacs.gmx_image import gmx_image
from biobb_analysis.gromacs.gmx_rgyr import gmx_rgyr
from biobb_analysis.gromacs.gmx_rms import gmx_rms
from biobb_analysis.gromacs.gmx_trjconv_str import gmx_trjconv_str
from biobb_gromacs.gromacs.editconf import editconf
from biobb_gromacs.gromacs.genion import genion
from biobb_gromacs.gromacs.grompp import grompp
from biobb_gromacs.gromacs.mdrun import mdrun
from biobb_gromacs.gromacs.pdb2gmx import pdb2gmx
from biobb_gromacs.gromacs.solvate import solvate
from biobb_io.api.pdb import pdb
from biobb_model.model.fix_side_chain import fix_side_chain


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pdb-code", default="1AKI")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--gmx-binary", required=True)
    parser.add_argument("--gmx-lib")
    parser.add_argument("--md-steps", type=int, default=50000)
    parser.add_argument("--equil-steps", type=int, default=5000)
    parser.add_argument("--min-steps", type=int, default=5000)
    parser.add_argument("--mpi-bin")
    parser.add_argument("--mpi-np", type=int)
    parser.add_argument("--omp-threads", type=int)
    return parser.parse_args()


def add_runtime(base: dict, args: argparse.Namespace, *, mdrun_step: bool = False) -> dict:
    props = {
        "binary_path": args.gmx_binary,
    }
    if args.gmx_lib:
        props["gmx_lib"] = args.gmx_lib
    props.update(base)
    if mdrun_step:
        if args.mpi_bin:
            props["mpi_bin"] = args.mpi_bin
        if args.mpi_np:
            props["mpi_np"] = args.mpi_np
        if args.omp_threads:
            props["num_threads_omp"] = args.omp_threads
    return props


def check_outputs(paths: list[str]) -> None:
    missing = [p for p in paths if not Path(p).is_file() or Path(p).stat().st_size == 0]
    if missing:
        raise RuntimeError(f"Missing or empty expected outputs: {missing}")


def main() -> None:
    args = parse_args()
    out = Path(args.output_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)
    os.chdir(out)

    pdb_code = args.pdb_code

    downloaded_pdb = f"{pdb_code}.pdb"
    pdb(output_pdb_path=downloaded_pdb, properties={"pdb_code": pdb_code})

    fixed_pdb = f"{pdb_code}_fixed.pdb"
    fix_side_chain(input_pdb_path=downloaded_pdb, output_pdb_path=fixed_pdb)

    output_pdb2gmx_gro = f"{pdb_code}_pdb2gmx.gro"
    output_pdb2gmx_top_zip = f"{pdb_code}_pdb2gmx_top.zip"
    pdb2gmx(
        input_pdb_path=fixed_pdb,
        output_gro_path=output_pdb2gmx_gro,
        output_top_zip_path=output_pdb2gmx_top_zip,
        properties=add_runtime({}, args),
    )

    output_editconf_gro = f"{pdb_code}_editconf.gro"
    editconf(
        input_gro_path=output_pdb2gmx_gro,
        output_gro_path=output_editconf_gro,
        properties=add_runtime({"box_type": "cubic", "distance_to_molecule": 1.0}, args),
    )

    output_solvate_gro = f"{pdb_code}_solvate.gro"
    output_solvate_top_zip = f"{pdb_code}_solvate_top.zip"
    solvate(
        input_solute_gro_path=output_editconf_gro,
        output_gro_path=output_solvate_gro,
        input_top_zip_path=output_pdb2gmx_top_zip,
        output_top_zip_path=output_solvate_top_zip,
        properties=add_runtime({}, args),
    )

    output_gppion_tpr = f"{pdb_code}_gppion.tpr"
    grompp(
        input_gro_path=output_solvate_gro,
        input_top_zip_path=output_solvate_top_zip,
        output_tpr_path=output_gppion_tpr,
        properties=add_runtime({"simulation_type": "ions", "maxwarn": 1}, args),
    )

    output_genion_gro = f"{pdb_code}_genion.gro"
    output_genion_top_zip = f"{pdb_code}_genion_top.zip"
    genion(
        input_tpr_path=output_gppion_tpr,
        output_gro_path=output_genion_gro,
        input_top_zip_path=output_solvate_top_zip,
        output_top_zip_path=output_genion_top_zip,
        properties=add_runtime({"neutral": True, "concentration": 0}, args),
    )

    output_gppmin_tpr = f"{pdb_code}_gppmin.tpr"
    grompp(
        input_gro_path=output_genion_gro,
        input_top_zip_path=output_genion_top_zip,
        output_tpr_path=output_gppmin_tpr,
        properties=add_runtime(
            {"simulation_type": "minimization", "mdp": {"emtol": "500", "nsteps": str(args.min_steps)}},
            args,
        ),
    )

    output_min_trr = f"{pdb_code}_min.trr"
    output_min_gro = f"{pdb_code}_min.gro"
    output_min_edr = f"{pdb_code}_min.edr"
    output_min_log = f"{pdb_code}_min.log"
    mdrun(
        input_tpr_path=output_gppmin_tpr,
        output_trr_path=output_min_trr,
        output_gro_path=output_min_gro,
        output_edr_path=output_min_edr,
        output_log_path=output_min_log,
        properties=add_runtime({}, args, mdrun_step=True),
    )

    output_min_ene_xvg = f"{pdb_code}_min_ene.xvg"
    gmx_energy(
        input_energy_path=output_min_edr,
        output_xvg_path=output_min_ene_xvg,
        properties=add_runtime({"terms": ["Potential"]}, args),
    )

    output_gppnvt_tpr = f"{pdb_code}_gppnvt.tpr"
    grompp(
        input_gro_path=output_min_gro,
        input_top_zip_path=output_genion_top_zip,
        output_tpr_path=output_gppnvt_tpr,
        properties=add_runtime(
            {
                "simulation_type": "nvt",
                "mdp": {"nsteps": str(args.equil_steps), "dt": 0.002, "Define": "-DPOSRES"},
            },
            args,
        ),
    )

    output_nvt_trr = f"{pdb_code}_nvt.trr"
    output_nvt_gro = f"{pdb_code}_nvt.gro"
    output_nvt_edr = f"{pdb_code}_nvt.edr"
    output_nvt_log = f"{pdb_code}_nvt.log"
    output_nvt_cpt = f"{pdb_code}_nvt.cpt"
    mdrun(
        input_tpr_path=output_gppnvt_tpr,
        output_trr_path=output_nvt_trr,
        output_gro_path=output_nvt_gro,
        output_edr_path=output_nvt_edr,
        output_log_path=output_nvt_log,
        output_cpt_path=output_nvt_cpt,
        properties=add_runtime({}, args, mdrun_step=True),
    )

    output_nvt_temp_xvg = f"{pdb_code}_nvt_temp.xvg"
    gmx_energy(
        input_energy_path=output_nvt_edr,
        output_xvg_path=output_nvt_temp_xvg,
        properties=add_runtime({"terms": ["Temperature"]}, args),
    )

    output_gppnpt_tpr = f"{pdb_code}_gppnpt.tpr"
    grompp(
        input_gro_path=output_nvt_gro,
        input_top_zip_path=output_genion_top_zip,
        output_tpr_path=output_gppnpt_tpr,
        input_cpt_path=output_nvt_cpt,
        properties=add_runtime({"simulation_type": "npt", "mdp": {"nsteps": str(args.equil_steps)}}, args),
    )

    output_npt_trr = f"{pdb_code}_npt.trr"
    output_npt_gro = f"{pdb_code}_npt.gro"
    output_npt_edr = f"{pdb_code}_npt.edr"
    output_npt_log = f"{pdb_code}_npt.log"
    output_npt_cpt = f"{pdb_code}_npt.cpt"
    mdrun(
        input_tpr_path=output_gppnpt_tpr,
        output_trr_path=output_npt_trr,
        output_gro_path=output_npt_gro,
        output_edr_path=output_npt_edr,
        output_log_path=output_npt_log,
        output_cpt_path=output_npt_cpt,
        properties=add_runtime({}, args, mdrun_step=True),
    )

    output_npt_pd_xvg = f"{pdb_code}_npt_PD.xvg"
    gmx_energy(
        input_energy_path=output_npt_edr,
        output_xvg_path=output_npt_pd_xvg,
        properties=add_runtime({"terms": ["Pressure", "Density"]}, args),
    )

    output_gppmd_tpr = f"{pdb_code}_gppmd.tpr"
    grompp(
        input_gro_path=output_npt_gro,
        input_top_zip_path=output_genion_top_zip,
        output_tpr_path=output_gppmd_tpr,
        input_cpt_path=output_npt_cpt,
        properties=add_runtime({"simulation_type": "free", "mdp": {"nsteps": str(args.md_steps)}}, args),
    )

    output_md_trr = f"{pdb_code}_md.trr"
    output_md_gro = f"{pdb_code}_md.gro"
    output_md_edr = f"{pdb_code}_md.edr"
    output_md_log = f"{pdb_code}_md.log"
    output_md_cpt = f"{pdb_code}_md.cpt"
    mdrun(
        input_tpr_path=output_gppmd_tpr,
        output_trr_path=output_md_trr,
        output_gro_path=output_md_gro,
        output_edr_path=output_md_edr,
        output_log_path=output_md_log,
        output_cpt_path=output_md_cpt,
        properties=add_runtime({}, args, mdrun_step=True),
    )

    output_rms_first = f"{pdb_code}_rms_first.xvg"
    gmx_rms(
        input_structure_path=output_gppmd_tpr,
        input_traj_path=output_md_trr,
        output_xvg_path=output_rms_first,
        properties=add_runtime({"selection": "Backbone"}, args),
    )

    output_rms_exp = f"{pdb_code}_rms_exp.xvg"
    gmx_rms(
        input_structure_path=output_gppmin_tpr,
        input_traj_path=output_md_trr,
        output_xvg_path=output_rms_exp,
        properties=add_runtime({"selection": "Backbone"}, args),
    )

    output_rgyr = f"{pdb_code}_rgyr.xvg"
    gmx_rgyr(
        input_structure_path=output_gppmin_tpr,
        input_traj_path=output_md_trr,
        output_xvg_path=output_rgyr,
        properties=add_runtime({"selection": "Backbone"}, args),
    )

    output_imaged_traj = f"{pdb_code}_imaged_traj.trr"
    gmx_image(
        input_traj_path=output_md_trr,
        input_top_path=output_gppmd_tpr,
        output_traj_path=output_imaged_traj,
        properties=add_runtime(
            {"center_selection": "Protein", "output_selection": "Protein", "pbc": "mol", "center": True},
            args,
        ),
    )

    output_dry_gro = f"{pdb_code}_md_dry.gro"
    gmx_trjconv_str(
        input_structure_path=output_md_gro,
        input_top_path=output_gppmd_tpr,
        output_str_path=output_dry_gro,
        properties=add_runtime({"selection": "Protein"}, args),
    )

    expected = [
        output_md_trr,
        output_md_gro,
        output_md_edr,
        output_md_log,
        output_md_cpt,
        output_rms_first,
        output_rms_exp,
        output_rgyr,
        output_imaged_traj,
        output_dry_gro,
    ]
    check_outputs(expected)
    print("biobb_wf_md_setup completed")
    for path in expected:
        print(f"{path}\t{Path(path).stat().st_size}")


if __name__ == "__main__":
    main()
