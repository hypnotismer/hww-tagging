#!/bin/bash -xe

# CMSSW_10_6_30 still needs SL7.  On el9 submit nodes (lxplus / CMS Connect)
# re-enter this script inside the cmssw-el7 container, same as xggg-tagging.
if [ "${SINGULARITY_NAME}" != "el7:x86_64" ]; then
  echo "Entering cmssw-el7..."
  exec cmssw-el7 --command-to-run "/bin/bash" "-xe" "$0" "$@"
fi
echo "Now in cmssw-el7!"
echo "Command line: $0 $*"

INPUTFILES=$1
ISTRAIN=$2
JETRADIUS=$3
if ! [ -z "$4" ]; then
  EOSPATH=$4
fi

if [ -z "${JETRADIUS}" ]; then
  echo "JETRADIUS (physical anti-kT R, e.g. 0.8) is required"
  exit 1
fi

WORKDIR=`pwd`

source /cvmfs/cms.cern.ch/cmsset_default.sh

############ Start DNNTuples ############
export SCRAM_ARCH=slc7_amd64_gcc700
scram p CMSSW CMSSW_10_6_30
cd CMSSW_10_6_30/src
eval `scram runtime -sh`

git clone git@github.com:hypnotismer/DNNTuples.git DeepNTuples -b dev-UL-VR
bash DeepNTuples/Ntupler/scripts/install_onnxruntime.sh

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
  echo $infile $idx "AK${JETRADIUS}"
  retry cmsRun DeepNtuplizerVR.py \
    inputFiles=${infile} \
    isTrainSample=${ISTRAIN} \
    jetRadius=${JETRADIUS} \
    jetPtMin=200 \
    jetPreselectionPtMin=170 \
    genJetPtMin=100
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
