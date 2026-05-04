#!/usr/bin/env bash
# 用法: bash check_lost.sh [CLUSTER_ID] [EXPECT_EVENTS]
# 勿用 source，否则路径/目录可能不对。
set -euo pipefail

CLUSTER="${1:-19591401}"
EXPECT_EVENTS="${2:-500}"
EOS_MGM="root://cceos.ihep.ac.cn:1094"
EOS_DIR="/store/user/zkou/sfTuples/BulkGravitonToHHTo6Glu_MX-Var_MH-260to650/20UL17MiniAODv2"
# submit_h3glu.jdl: Queue JOBNUM from seq 1 4000  => Process 0..3999
PROC_MAX=3999

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="${SCRIPT_DIR}/eos_miniv2_names.txt"
HAVE="${SCRIPT_DIR}/have.txt"
WANT="${SCRIPT_DIR}/want.txt"
HAVE_PAD="${SCRIPT_DIR}/have.pad"
WANT_PAD="${SCRIPT_DIR}/want.pad"
MISSING="${SCRIPT_DIR}/missing_${CLUSTER}.txt"
OTHER="${SCRIPT_DIR}/other_than_${CLUSTER}.txt"
GOOD_FILES="${SCRIPT_DIR}/good_files_${CLUSTER}.txt"
BAD_REPORT="${SCRIPT_DIR}/bad_or_incomplete_${CLUSTER}.txt"

echo "==> Listing ${EOS_MGM} ${EOS_DIR}"
eos "${EOS_MGM}" ls "${EOS_DIR}" \
  | sed 's|.*/||' \
  | grep -E '\.root$' \
  | sort > "${LIST}"

echo "==> ROOT files in listing: $(wc -l < "${LIST}")"

# 先做“存在 + 可读 + 事件数正确”校验：
# 只有能打开且 Events 树条目 == EXPECT_EVENTS 的文件，才计入 have。
# 远程逐个打开 ROOT 文件较慢；用 CHECK_WORKERS 控制并行度，例如 CHECK_WORKERS=16 bash check_lost.sh
python3 - "${LIST}" "${CLUSTER}" "${EXPECT_EVENTS}" "${EOS_MGM}" "${EOS_DIR}" "${HAVE}" "${GOOD_FILES}" "${BAD_REPORT}" <<'PY'
import concurrent.futures as futures
import os
import re
import sys
import warnings

list_file, cluster, expect_s, eos_mgm, eos_dir, have_path, good_files_path, bad_path = sys.argv[1:]
expect = int(expect_s)
pat = re.compile(rf"^miniv2_{re.escape(cluster)}-(\d+)\.root$")
workers = int(os.environ.get("CHECK_WORKERS", "8"))

with open(list_file, "r", encoding="utf-8") as f:
    items = []
    for name in (x.strip() for x in f if x.strip()):
        m = pat.match(name)
        if not m:
            continue
        proc = int(m.group(1))
        # xrootd 绝对路径需使用 root://host//store/...（双斜杠）
        full_path = f"/{eos_dir.strip('/')}/{name}"
        url = f"{eos_mgm}//{full_path.lstrip('/')}"
        items.append((proc, name, url))

def check_one(item):
    proc, name, url = item

    # CMS EDM 文件缺少字典时会打印大量 warning；这里只需 Events entries。
    warnings.filterwarnings("ignore", category=RuntimeWarning, message=".*no dictionary.*")
    try:
        import ROOT
    except Exception as exc:
        return ("bad", proc, name, f"import_ROOT_failed:{exc}")
    ROOT.gErrorIgnoreLevel = ROOT.kError

    try:
        tf = ROOT.TFile.Open(url)
    except Exception as exc:
        return ("bad", proc, name, f"open_exception:{exc}")
    if (not tf) or tf.IsZombie():
        return ("bad", proc, name, "open_failed")
    tree = tf.Get("Events")
    if not tree:
        tf.Close()
        return ("bad", proc, name, "missing_tree:Events")
    nent = int(tree.GetEntries())
    tf.Close()
    if nent != expect:
        return ("bad", proc, name, f"events={nent}")
    return ("good", proc, name, "")

good_proc = []
good_files = []
bad_lines = []

print(f"==> Checking Events entries with {workers} workers for {len(items)} files", flush=True)
done = 0
with futures.ProcessPoolExecutor(max_workers=workers) as ex:
    for status, proc, name, reason in ex.map(check_one, items, chunksize=4):
        done += 1
        if status == "good":
            good_proc.append(proc)
            good_files.append(name)
        else:
            bad_lines.append(f"{proc}\t{name}\t{reason}")
        if done % 100 == 0 or done == len(items):
            print(f"==> checked {done}/{len(items)}", flush=True)

good_proc = sorted(set(good_proc))
with open(have_path, "w", encoding="utf-8") as f:
    for p in good_proc:
        f.write(f"{p}\n")
with open(good_files_path, "w", encoding="utf-8") as f:
    for n in sorted(set(good_files)):
        f.write(f"{n}\n")
with open(bad_path, "w", encoding="utf-8") as f:
    for line in sorted(set(bad_lines), key=lambda s: int(s.split("\t", 1)[0])):
        f.write(f"{line}\n")
PY

echo "==> Valid files (exists + readable + Events=${EXPECT_EVENTS}): $(wc -l < "${HAVE}")"
echo "==> Bad/incomplete files for cluster ${CLUSTER}: $(wc -l < "${BAD_REPORT}")"
if [[ -s "${BAD_REPORT}" ]]; then
  echo "---- first 20 bad/incomplete (proc, file, reason) ----"
  head -20 "${BAD_REPORT}"
fi

# have.txt: 普通整数，便于阅读；have.pad: 4 位补零，供 comm（要求字典序与数值序一致）
awk '{ printf "%04d\n", $0 }' "${HAVE}" | sort > "${HAVE_PAD}"

# comm 默认要求“字典序”排序；纯数字用 sort -n 时 10 会排在 2 前，会触发 not in sorted order
seq 0 "${PROC_MAX}" | sort -n > "${WANT}"
awk '{ printf "%04d\n", $0 }' "${WANT}" | sort > "${WANT_PAD}"
comm -23 "${WANT_PAD}" "${HAVE_PAD}" | awk '{ print $0 + 0 }' > "${MISSING}"

echo "==> Cluster ${CLUSTER}: have $(wc -l < "${HAVE}") / expect $((PROC_MAX + 1))"
echo "==> Missing count: $(wc -l < "${MISSING}")"
if [[ -s "${MISSING}" ]]; then
  echo "---- first 20 missing ProcId ----"
  head -20 "${MISSING}"
fi

grep -vE "^miniv2_${CLUSTER}-[0-9]+\\.root\$" "${LIST}" > "${OTHER}" || true
echo "==> Not miniv2_${CLUSTER}-<n>.root: $(wc -l < "${OTHER}")"
if [[ -s "${OTHER}" ]]; then
  echo "---- first 20 other names ----"
  head -20 "${OTHER}"
fi

echo "==> Wrote: ${LIST} ${HAVE} ${GOOD_FILES} ${BAD_REPORT} ${MISSING} ${OTHER}"
