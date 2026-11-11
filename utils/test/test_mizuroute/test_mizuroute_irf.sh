#!/usr/bin/env bash
set -euo pipefail

# Compare coupled and standalone IRF on the bundled Provo chain, then test lakes.
# Requires SUMMA with mizuRoute, bin/route_runoff, and python3 with netCDF4.
# Usage: bash test_mizuroute_irf.sh [work_dir]
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMA_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
WORK_DIR="${1:-$TEST_DIR/toy_prob/irf}"
ROUTE_EXE="$SUMMA_ROOT/bin/route_runoff"

if [[ ! -x "$ROUTE_EXE" ]]; then
  echo "ERROR: online/offline checks require $ROUTE_EXE; see make_mizuRoute.sh"
  exit 1
fi
mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

CASE_DIR="$WORK_DIR/river_3600"
bash "$TEST_DIR/test_mizuroute_bundled.sh" "$CASE_DIR" 1
python3 - "$CASE_DIR" "$ROUTE_EXE" <<'PYEOF'
import glob
import os
import shutil
import subprocess
import sys

import numpy as np
from netCDF4 import Dataset, date2num, num2date

work, executable = sys.argv[1], sys.argv[2]
units = "seconds since 2017-01-01 00:00:00"
outputs = glob.glob(os.path.join(work, "output", "*toy_prob*timestep.nc"))
assert len(outputs) == 1, f"expected one coupled output, found {outputs}"
with Dataset(outputs[0]) as c:
    assert list(c["method"][:]) == [1], "coupled run did not use IRF"
    runoff = c["q_basin"][:]
    discharge = c["Q_reach"][:, :, 0]
    hru = c["mizu_hru"][:]
    reach = c["seg"][:]
    seconds = date2num(num2date(c["time"][:], c["time"].units), units)
seconds = np.rint(seconds)

# Use the host runoff directly, preserving its precision.
standalone = os.path.join(work, "standalone")
os.makedirs(os.path.join(standalone, "output"), exist_ok=True)
with Dataset(os.path.join(standalone, "forcing.nc"), "w") as f:
    f.createDimension("time", len(seconds))
    f.createDimension("hru", len(hru))
    t = f.createVariable("time", "f8", ("time",))
    t.units, t.calendar = units, "standard"
    t[:] = seconds
    f.createVariable("hruId", "i8", ("hru",))[:] = hru
    q = f.createVariable("runoff", "f8", ("time", "hru"))
    q.units = "m/s"
    q[:] = runoff
with open(os.path.join(standalone, "forcing_list.txt"), "w") as f:
    f.write("forcing.nc\n")

dates = num2date(seconds[[0, -1]], units)
settings = os.path.join(work, "settings")
# Explicit false lake flags avoid upstream's uninitialized ISLAKE in river-only mode.
shutil.copyfile(os.path.join(settings, "topology.nc"), os.path.join(standalone, "topology.nc"))
with Dataset(os.path.join(standalone, "topology.nc"), "a") as topology:
    topology.createVariable("islake", "i4", ("seg",))[:] = 0
    topology.createVariable("LakeModelType", "i4", ("seg",))[:] = 0
control = f"""<case_name> irf
<sim_start> {dates[0].strftime('%Y-%m-%d %H:%M:%S')}
<sim_end> {dates[1].strftime('%Y-%m-%d %H:%M:%S')}
<route_opt> 1
<doesBasinRoute> 0
<dt_qsim> 3600
<dt_ro> 3600
<ro_time_stamp> start
<is_lake_sim> T
<LakeInputOption> 2
<scale_factor_Ep> 0
<scale_factor_prec> 0
<is_remap> F
<restart_write> never
<ancil_dir> {standalone}/
<input_dir> {standalone}/
<output_dir> {standalone}/output/
<fname_ntopOld> topology.nc
<dname_sseg> seg
<dname_nhru> hru
<fname_qsim> forcing_list.txt
<vname_qsim> runoff
<vname_time> time
<vname_hruid> hruId
<dname_time> time
<dname_hruid> hru
<units_qsim> m/s
<param_nml> ../settings/param.nml.default
<varname_area> area
<varname_length> length
<varname_slope> slope
<varname_HRUid> hruId
<varname_hruSegId> hruToSegId
<varname_segId> segId
<varname_downSegId> downSegId
<varname_islake> islake
<varname_lakeModelType> LakeModelType
<pio_netcdf_type> netcdf
<newFileFrequency> single
<outputFrequency> 1
<IRFroutedRunoff> T
"""
control_file = os.path.join(standalone, "irf.control")
with open(control_file, "w") as f:
    f.writelines(line + " !\n" for line in control.splitlines())
log = os.path.join(standalone, "run.log")
with open(log, "w") as f:
    result = subprocess.run([executable, control_file], cwd=standalone,
                            stdout=f, stderr=subprocess.STDOUT)
assert result.returncode == 0, f"standalone mizuRoute failed; see {log}"

outputs = glob.glob(os.path.join(standalone, "output", "irf.h.*.nc"))
assert len(outputs) == 1, f"expected one standalone output, found {outputs}"
with Dataset(outputs[0]) as s:
    offline_reach = list(s["reachID"][:])
    offline = s["IRFroutedRunoff"][:]
    offline_times = date2num(num2date(s["time"][:], s["time"].units), units)
assert len(offline_reach) == len(reach) and set(offline_reach) == set(reach)
assert np.array_equal(offline_times, seconds), "routing times differ"
offline = offline[:, [offline_reach.index(r) for r in reach]]
assert np.array_equal(discharge.astype("f4"), offline.astype("f4")), (
    "hourly IRF discharge differs at single precision"
)
print("PASS: hourly IRF discharge matches exactly at single precision")
PYEOF

# Run the existing lake checks with IRF.
bash "$TEST_DIR/test_mizuroute_lakes.sh" "$WORK_DIR/lakes_irf" 1
echo "PASS: IRF online/offline routing and lake checks"
