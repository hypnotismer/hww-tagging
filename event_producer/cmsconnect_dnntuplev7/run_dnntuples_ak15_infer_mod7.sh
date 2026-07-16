#!/bin/bash
set -euo pipefail
set -x

#use CMSSW-el7
if [ "${SINGULARITY_NAME:-}" != "el7:x86_64" ]; then
echo "Entering cmssw-el7..."
exec cmssw-el7 --command-to-run "/bin/bash" "$0" "$@"
fi
echo "Now in cmssw-el7!"
echo "Command line: $0 $*"

INPUTFILES=${1:?Missing input files}
ISTRAIN=${2:?Missing ISTRAIN argument}
if [ "${ISTRAIN}" != "0" ]; then
  echo "run_dnntuples_ak15_infer_mod7.sh is for inference only; expected ISTRAIN=0, got ISTRAIN=${ISTRAIN}"
  exit 1
fi
if ! [ -z "${3:-}" ]; then
  EOSPATH=$3
fi

WORKDIR=`pwd`

source /cvmfs/cms.cern.ch/cmsset_default.sh

############ Start DNNTuples ############
export SCRAM_ARCH=slc7_amd64_gcc700
scram p CMSSW CMSSW_10_6_30
cd CMSSW_10_6_30/src
eval `scram runtime -sh`

# use an updated onnxruntime package
curl -s --retry 10 https://raw.githubusercontent.com/colizz/DNNTuples/dev-UL-hww/Ntupler/scripts/install_onnxruntime.sh -o install_onnxruntime.sh
bash install_onnxruntime.sh
rm -f install_onnxruntime.sh

# clone this repo into "DeepNTuples" directory
git clone git@github.com:hypnotismer/DNNTuples.git DeepNTuples -b dev-UL-v10-finetune-xggg

# The copied framework keeps only 1/7 of inference events for QCD/TTBar by
# default. XGGG inference is a signal sample, so widen that skim to every
# inference sample before compiling.
python <<'PY'
import re

path = "DeepNTuples/Ntupler/src/JetInfoFiller.cc"
with open(path) as handle:
    text = handle.read()
pattern = re.compile(
    r"^(?P<indent>[ \t]*)// QCD and ttbar samples for inference: keep only 1/7 of the events\n"
    r"(?P=indent)if \(!isTrainSample_ && !keepAllEvents_ && \(isQCDSample_ \|\| isTTBarSample_\)\) \{\n"
    r"(?P=indent)[ \t]+if \(event_ %\s*7 != 0\) return false;\n"
    r"(?P=indent)\}\n",
    re.MULTILINE,
)
new = """  // Inference samples: keep only events with event number modulo 7 equal to 0.
  if (!isTrainSample_ && !keepAllEvents_) {
    if (event_ %7 != 0) return false;
  }
"""
text, n_replaced = pattern.subn(new, text, count=1)
if n_replaced != 1:
    raise RuntimeError("Could not patch the expected inference event skim block")
if "(isQCDSample_ || isTTBarSample_)" in text:
    raise RuntimeError("QCD/TTBar-only inference skim is still present after patching")
with open(path, "w") as handle:
    handle.write(text)

with open(path) as handle:
    patched = handle.read()
start = patched.index("// Inference samples: keep only events")
print("Patched JetInfoFiller.cc skim block:")
print(patched[start:patched.index("// event information", start)])
PY

scram b -j8

cd DeepNTuples/Ntupler/test/

function retry {
  local n=1
  local max=5
  local delay=5
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed. Attempt $n/$max:"
        sleep $delay;
      else
        echo "The command has failed after $n attempts."
        return 1
      fi
    }
  done
}

### process files iteratively
IFS=',' read -ra ADDR <<< "$INPUTFILES"
idx=0
for infile in "${ADDR[@]}"; do
  echo $infile $idx
  retry cmsRun DeepNtuplizerAK15.py inputFiles=${infile} isTrainSample=${ISTRAIN} keepAllEvents=0
  mv output.root dnntuple_raw${idx}.root
  idx=$(($idx+1))
done
if [ $idx == 1 ]; then
  mv dnntuple_raw0.root dnntuple.root
else
  hadd dnntuple.root dnntuple_raw*.root
fi
### end processing file

mv dnntuple.root ${WORKDIR}/dnntuple.root

if ! [ -z "$EOSPATH" ]; then
  xrdcp --silent -p -f ${WORKDIR}/dnntuple.root $EOSPATH
fi
touch ${WORKDIR}/dummy.cc
