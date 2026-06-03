#!/usr/bin/env bash

prepare_differentialabundance_gse50790_inputs() {
  local root="$1"
  local data_dir="$root/data/nf-core_differentialabundance/gse50790_geo"
  local soft_gz="$data_dir/GSE50790_family.soft.gz"
  local observations="$data_dir/GSE50790.observations.csv"
  local contrasts="$data_dir/GSE50790.contrasts.csv"

  mkdir -p "$data_dir"

  if [ ! -s "$soft_gz" ] || ! gzip -t "$soft_gz"; then
    rm -f "$soft_gz" "$soft_gz.part"
    curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors \
      -o "$soft_gz.part" \
      "https://ftp.ncbi.nlm.nih.gov/geo/series/GSE50nnn/GSE50790/soft/GSE50790_family.soft.gz"
    gzip -t "$soft_gz.part"
    mv "$soft_gz.part" "$soft_gz"
  fi

  python3 - "$soft_gz" "$observations" <<'PY'
import csv
import gzip
import sys

soft_gz, observations = sys.argv[1:]
rows = []
current = None

with gzip.open(soft_gz, "rt", errors="replace") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if line.startswith("^SAMPLE = "):
            if current and current.get("id") in {f"GSM122934{i}" for i in range(1, 9)}:
                rows.append(current)
            current = {"id": line.split("=", 1)[1].strip()}
            continue
        if current is None:
            continue
        if line.startswith("!Sample_title = "):
            title = line.split("=", 1)[1].strip()
            current["name"] = title.removeprefix("Gudjohnsson_")
        elif line.startswith("!Sample_characteristics_ch1 = patient:"):
            current["patient"] = line.split("patient:", 1)[1].strip()
        elif line.startswith("!Sample_characteristics_ch1 = phenotype:"):
            current["phenotype"] = line.split("phenotype:", 1)[1].strip()

if current and current.get("id") in {f"GSM122934{i}" for i in range(1, 9)}:
    rows.append(current)

if len(rows) != 8:
    raise SystemExit(f"expected 8 GSE50790 samples, found {len(rows)}")

for row in rows:
    missing = [key for key in ("id", "name", "patient", "phenotype") if not row.get(key)]
    if missing:
        raise SystemExit(f"sample {row.get('id')} missing {missing}")

with open(observations, "w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=["id", "name", "patient", "phenotype"])
    writer.writeheader()
    writer.writerows(rows)
PY

  cat > "$contrasts" <<'EOF'
id,variable,reference,target,blocking
phenotype_uninvolved_lesional,phenotype,uninvolved,lesional,patient
EOF

  export DIFFABUND_INPUT="$observations"
  export DIFFABUND_CONTRASTS="$contrasts"
}
