#!/usr/bin/env bash
# 會議錄音/影片 → 逐字稿（本機 Whisper large-v3-turbo）
# 可攜版：自動偵測/安裝引擎，不寫死任何個人路徑。
#
# 三種引擎模式：
#   mlx（預設）Apple Silicon GPU。實測 M4：25.9 分鐘會議 2 分 48 秒（9.3x realtime）
#   cpu（保留）原本的 openai-whisper／PyTorch CPU。同檔約 35 分鐘，CPU 工作量多 40 倍
#   both（比較）兩個都跑，輸出到 <輸出資料夾>/mlx 與 /cpu，並印並排比較表
#
# 用法:
#   transcribe.sh <輸入檔> [語言=zh] [initial_prompt] [輸出資料夾] [引擎=mlx|cpu|both]
# 範例:
#   transcribe.sh "會議.mp4" zh "這是一場關於報價系統的會議，參與者有 Ray 與 Ben。" ./out
#   transcribe.sh "會議.mp4" zh "" ./out both     # 兩引擎並排比較
# 也可用環境變數覆蓋：TRANSCRIBE_ENGINE / MLX_MODEL / CPU_MODEL
set -euo pipefail

# UTF-8 locale：腳本含中日韓全形字元，locale 未設會導致多位元組字元被誤判
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

print_help() {
  printf '%s\n' \
    '用法:' \
    '  transcribe.sh [選項] <輸入檔> [語言=zh] [initial_prompt] [輸出資料夾] [引擎=mlx|cpu|both]' \
    '' \
    '選項:' \
    '  -h, --help       顯示這份說明，不需要安裝任何引擎' \
    '  --overwrite      轉錄成功後替換既有輸出；舊輸出會先保留到備份資料夾' \
    '  --               結束選項解析，允許輸入路徑或 prompt 以 - 開頭' \
    '' \
    '引擎:' \
    '  mlx              Apple Silicon 的 MLX 引擎（預設）' \
    '  cpu              openai-whisper CPU 引擎' \
    '  both             先跑 MLX，再跑 CPU，成功後才產生並排比較' \
    '' \
    '說明:' \
    '  既有 positional 參數順序保持不變。輸入會先做副檔名檢查；有 ffprobe 時' \
    '  也會確認檔案含 audio/video stream。輸出先寫入暫存 run directory，完成' \
    '  輸出檢查、轉繁與品質稽核後才發布。' \
    '  音檔與逐字稿留在本機；首次使用仍會下載 Python 套件與模型。' \
    '' \
    '環境變數:' \
    '  TRANSCRIBE_ENGINE / MLX_MODEL / CPU_MODEL' \
    '  MLX_PACKAGE / CPU_PACKAGE / OPENCC_PACKAGE' \
    '  TO_TRADITIONAL=0 可明確略過 OpenCC 轉繁。'
}

POSITIONAL=()
OVERWRITE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --overwrite)
      OVERWRITE=1
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        POSITIONAL+=("$1")
        shift
      done
      break
      ;;
    -*)
      echo "未知選項: $1" >&2
      echo "請執行 --help 查看用法。" >&2
      exit 2
      ;;
    *)
      POSITIONAL+=("$1")
      ;;
  esac
  shift
done

ARGC="${#POSITIONAL[@]}"
[ "${ARGC}" -ge 1 ] || {
  echo "缺少輸入檔。請提供音檔/影片路徑，或執行 --help 查看用法。" >&2
  exit 2
}
[ "${ARGC}" -le 5 ] || {
  echo "參數過多：最多接受輸入檔、語言、initial_prompt、輸出資料夾、引擎共 5 個 positional 參數。" >&2
  exit 2
}

INPUT="${POSITIONAL[0]}"
# 注意：變數名不可用 LANG（那是系統 locale 環境變數，覆蓋會破壞 UTF-8 處理）
WHISPER_LANG="zh"
[ "${ARGC}" -ge 2 ] && [ -n "${POSITIONAL[1]}" ] && WHISPER_LANG="${POSITIONAL[1]}"
PROMPT=""
[ "${ARGC}" -ge 3 ] && PROMPT="${POSITIONAL[2]}"
OUTDIR="$(dirname -- "${INPUT}")/transcribe_out"
[ "${ARGC}" -ge 4 ] && [ -n "${POSITIONAL[3]}" ] && OUTDIR="${POSITIONAL[3]}"
ENGINE="${TRANSCRIBE_ENGINE:-mlx}"
[ "${ARGC}" -ge 5 ] && [ -n "${POSITIONAL[4]}" ] && ENGINE="${POSITIONAL[4]}"

case "${ENGINE}" in
  mlx|cpu|both) ;;
  *) echo "引擎只能是 mlx / cpu / both（收到: ${ENGINE}）" >&2; exit 2 ;;
esac

is_supported_extension() {
  local extension
  extension="${INPUT##*.}"
  [ "${extension}" != "${INPUT}" ] || extension=""
  extension="$(printf '%s' "${extension}" | tr '[:upper:]' '[:lower:]')"
  case "${extension}" in
    mp3|mp4|m4a|wav|mkv|mov|avi|webm|flac|ogg|oga|opus|aac|wma|mpeg|mpg|3gp|ts|m4v)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_input() {
  [ -f "${INPUT}" ] || {
    echo "找不到輸入檔: ${INPUT}" >&2
    return 1
  }
  [ -r "${INPUT}" ] || {
    echo "無法讀取輸入檔: ${INPUT}" >&2
    return 1
  }

  local known_extension=0
  is_supported_extension && known_extension=1 || true
  if command -v ffprobe >/dev/null 2>&1; then
    local streams
    if ! streams="$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "${INPUT}" 2>/dev/null)"; then
      echo "ffprobe 無法讀取輸入檔，請確認檔案未損壞: ${INPUT}" >&2
      return 1
    fi
    case "${streams}" in
      *audio*|*video*) ;;
      *)
        echo "輸入檔不是可辨識的媒體檔（沒有 audio/video stream）: ${INPUT}" >&2
        return 1
        ;;
    esac
  elif [ "${known_extension}" -ne 1 ]; then
    echo "輸入檔不是可辨識的媒體檔（副檔名不在支援清單，且找不到 ffprobe）: ${INPUT}" >&2
    return 1
  fi
}

validate_input || exit 2

MLX_MODEL="${MLX_MODEL:-mlx-community/whisper-large-v3-turbo}"
CPU_MODEL="${CPU_MODEL:-turbo}"
CACHE_ROOT="${XDG_CACHE_HOME:-${HOME}/.cache}/transcribe-meeting"
MLX_VENV="${MLX_VENV:-${CACHE_ROOT}/mlx-venv}"
CPU_VENV="${CPU_VENV:-${CACHE_ROOT}/cpu-venv}"
MLX_PACKAGE="${MLX_PACKAGE:-mlx-whisper==0.4.2}"
CPU_PACKAGE="${CPU_PACKAGE:-openai-whisper==20240930}"
OPENCC_PACKAGE="${OPENCC_PACKAGE:-opencc-python-reimplemented==0.1.7}"
# 轉繁：Whisper 兩個引擎都會漏簡體字（實測 0.5–3%，跟段落內容有關），
# 統一轉繁後 mlx/cpu 的逐字稿相似度會跳升約 5 個百分點——
# 代表原本測到的差異有一大半只是繁簡不一致，不是內容錯誤。設 0 可關閉。
TO_TRADITIONAL="${TO_TRADITIONAL:-1}"
# s2tw = 台灣標準字形。注意它會把「台灣」正規化成「臺灣」（教育部標準用字）；
# 若不想要，設 OPENCC_CONFIG=s2t（但會多出「纔」「爲」等冷僻異體字）。
OPENCC_CONFIG="${OPENCC_CONFIG:-s2tw}"

# --- 前置檢查 ---
command -v python3 >/dev/null 2>&1 || { echo "找不到 python3，請先安裝 Python 3"; exit 1; }
command -v ffmpeg  >/dev/null 2>&1 || { echo "找不到 ffmpeg。macOS 請執行: brew install ffmpeg"; exit 1; }

DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "${INPUT}" 2>/dev/null | head -1 || true)"
# ffprobe metadata should be numeric, but corrupt/foreign files can return other text.
# Normalize it before using it in QC and the both-mode estimate.
DUR="$(python3 - "${DUR}" <<'PY'
import math
import sys

try:
    value = float(sys.argv[1])
except (IndexError, ValueError):
    value = 0.0
print(value if math.isfinite(value) and value > 0 else 0)
PY
)"

# --- 找 cpu 版 whisper（不寫死路徑，跨機器） ---
find_whisper() {
  if [ -x "${CPU_VENV}/bin/whisper" ]; then
    echo "${CPU_VENV}/bin/whisper"
    return 0
  fi
  command -v whisper 2>/dev/null && return 0
  local ub
  ub="$(python3 -m site --user-base 2>/dev/null || true)"
  if [ -n "${ub}" ] && [ -x "${ub}/bin/whisper" ]; then
    echo "${ub}/bin/whisper"; return 0
  fi
  local p
  for p in "${HOME}/Library/Python/"*/bin/whisper "${HOME}/.local/bin/whisper"; do
    [ -x "${p}" ] && { echo "${p}"; return 0; }
  done
  return 1
}

# --- 挑一個 mlx-whisper 裝得起來的 python ---
# mlx-whisper 依賴 numba，numba 對最新版 Python 通常慢好幾個月才出 wheel，
# 所以優先挑已知可用的版本，而不是直接用系統 python3。
pick_python() {
  local p
  for p in python3.13 python3.12 python3.11 python3.10; do
    command -v "${p}" >/dev/null 2>&1 && { echo "${p}"; return 0; }
  done
  if python3 -c 'import sys; sys.exit(0 if (3,10) <= sys.version_info[:2] <= (3,13) else 1)' 2>/dev/null; then
    echo python3; return 0
  fi
  return 1
}

prepare_cached_venv() {
  local venv="$1"
  local py="$2"
  if [ -x "${venv}/bin/python" ]; then
    return 0
  fi
  if [ -e "${venv}" ]; then
    echo "快取環境不完整，為避免覆蓋而停止: ${venv}" >&2
    return 1
  fi
  mkdir -p "$(dirname "${venv}")"
  if command -v uv >/dev/null 2>&1; then
    uv venv --python "${py}" "${venv}" >&2
  else
    "${py}" -m venv "${venv}" >&2
  fi
}

# --- 備妥 mlx-whisper（獨立 venv，不汙染系統/使用者 site-packages） ---
prepare_mlx() {
  if [ -x "${MLX_VENV}/bin/mlx_whisper" ]; then
    MLXBIN="${MLX_VENV}/bin/mlx_whisper"; return 0
  fi
  local py
  py="$(pick_python)" || { echo "找不到 3.10–3.13 的 python（mlx-whisper 依賴 numba，不支援太新的版本）" >&2; return 1; }
  echo "首次使用 MLX 引擎，建立獨立環境（${py} @ ${MLX_VENV}）..." >&2
  prepare_cached_venv "${MLX_VENV}" "${py}" || return 1
  if command -v uv >/dev/null 2>&1; then
    uv pip install --python "${MLX_VENV}/bin/python" "${MLX_PACKAGE}" >&2
  else
    "${MLX_VENV}/bin/python" -m pip install -q "${MLX_PACKAGE}" >&2
  fi
  [ -x "${MLX_VENV}/bin/mlx_whisper" ] || { echo "mlx-whisper 安裝後找不到執行檔" >&2; return 1; }
  MLXBIN="${MLX_VENV}/bin/mlx_whisper"
}

prepare_cpu() {
  if ! WHISPER="$(find_whisper)"; then
    local py
    py="$(pick_python)" || { echo "找不到 3.10–3.13 的 python，無法建立 CPU 快取環境" >&2; return 1; }
    echo "未偵測到 openai-whisper，建立 CPU 專用快取環境（首次約需幾分鐘）..." >&2
    prepare_cached_venv "${CPU_VENV}" "${py}" || return 1
    if command -v uv >/dev/null 2>&1; then
      uv pip install --python "${CPU_VENV}/bin/python" "${CPU_PACKAGE}" >&2
    else
      "${CPU_VENV}/bin/python" -m pip install -q "${CPU_PACKAGE}" >&2
    fi
    WHISPER="${CPU_VENV}/bin/whisper"
    [ -x "${WHISPER}" ] || { echo "openai-whisper 安裝後找不到執行檔: ${WHISPER}" >&2; return 1; }
  fi
}

# --- 找一個能 import opencc 的 python（轉繁用） ---
OPENCC_PY=""
ensure_opencc() {
  local candidate
  for candidate in "${MLX_VENV}/bin/python" "${CPU_VENV}/bin/python"; do
    if [ -x "${candidate}" ] && "${candidate}" -c "import opencc" 2>/dev/null; then
      OPENCC_PY="${candidate}"
      return 0
    fi
  done
  if python3 -c "import opencc" 2>/dev/null; then
    OPENCC_PY="python3"
    return 0
  fi

  local target_venv="${CPU_VENV}"
  [ "${ENGINE}" != "cpu" ] && target_venv="${MLX_VENV}"
  local py
  py="$(pick_python)" || return 1
  prepare_cached_venv "${target_venv}" "${py}" || return 1
  echo "安裝 opencc（轉繁用，裝進 ${target_venv}）..." >&2
  if command -v uv >/dev/null 2>&1; then
    uv pip install --python "${target_venv}/bin/python" "${OPENCC_PACKAGE}" >&2
  else
    "${target_venv}/bin/python" -m pip install -q "${OPENCC_PACKAGE}" >&2
  fi
  if "${target_venv}/bin/python" -c "import opencc" 2>/dev/null; then
    OPENCC_PY="${target_venv}/bin/python"
    return 0
  fi
  return 1
}

# --- 統一轉繁體（就地改寫 txt/srt/vtt/tsv/json） ---
convert_traditional() {  # $1=輸出資料夾
  [ "${TO_TRADITIONAL}" = "1" ] || return 0
  if [ -z "${OPENCC_PY}" ] && ! ensure_opencc; then
    echo "OpenCC 不可用，未發布輸出；如需略過轉繁請明確設定 TO_TRADITIONAL=0。" >&2
    return 1
  fi
  "${OPENCC_PY}" - "$1" "${OPENCC_CONFIG}" <<'PY'
import glob, json, os, sys
from opencc import OpenCC
# s2tw = 簡→繁（台灣標準字形）。不要用 s2t：它會產生「纔」「爲」「稽覈」等冷僻異體字。
# 也不要用 s2twp：那會連詞彙一起換（實測改動量是 27 倍），對含專有名詞的逐字稿太激進。
cc = OpenCC(sys.argv[2])
outdir = sys.argv[1]
changed = 0

for p in glob.glob(os.path.join(outdir, "*")):
    ext = os.path.splitext(p)[1].lower()
    if ext == ".json":
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
        def walk(o):
            global changed
            if isinstance(o, dict):
                return {k: (conv(v) if k == "text" and isinstance(v, str) else walk(v))
                        for k, v in o.items()}
            if isinstance(o, list):
                return [walk(x) for x in o]
            return o
        def conv(s):
            global changed
            t = cc.convert(s)
            changed += sum(1 for a, b in zip(s, t) if a != b)
            return t
        with open(p, "w", encoding="utf-8") as f:
            json.dump(walk(data), f, ensure_ascii=False, indent=1)
    elif ext in (".txt", ".srt", ".vtt", ".tsv"):
        # 時間戳是 ASCII，s2t 不會動到，整檔轉換是安全的
        with open(p, encoding="utf-8") as f:
            s = f.read()
        t = cc.convert(s)
        if t != s:
            changed += sum(1 for a, b in zip(s, t) if a != b)
            with open(p, "w", encoding="utf-8") as f:
                f.write(t)

print(f"  轉繁完成：修正 {changed} 個簡體字")
PY
}

validate_output_target() {
  OUTDIR="${OUTDIR%/}"
  [ -n "${OUTDIR}" ] || OUTDIR="/"
  OUTDIR_PARENT="$(dirname "${OUTDIR}")"
  mkdir -p "${OUTDIR_PARENT}" || {
    echo "無法建立輸出父資料夾: ${OUTDIR_PARENT}" >&2
    return 1
  }
  if [ -L "${OUTDIR}" ]; then
    echo "輸出路徑是 symbolic link，為避免改寫其他位置而停止: ${OUTDIR}" >&2
    return 1
  fi
  if [ -e "${OUTDIR}" ]; then
    if [ ! -d "${OUTDIR}" ]; then
      echo "輸出路徑不是資料夾: ${OUTDIR}" >&2
      return 1
    fi
    if [ "${OVERWRITE}" -ne 1 ]; then
      echo "輸出資料夾已存在；為避免覆蓋，請換路徑或加 --overwrite。既有內容未變更: ${OUTDIR}" >&2
      return 1
    fi
  fi
  local input_abs outdir_abs input_dir
  input_dir="$(cd "$(dirname -- "${INPUT}")" && pwd -P)"
  input_abs="${input_dir}/$(basename -- "${INPUT}")"
  outdir_abs="$(cd "${OUTDIR_PARENT}" && pwd -P)/$(basename -- "${OUTDIR}")"
  case "${input_abs}" in
    "${outdir_abs}"/*)
      echo "輸出資料夾包含輸入檔；為避免 --overwrite 移動使用者資料而停止: ${OUTDIR}" >&2
      return 1
      ;;
  esac
}

RUN_ROOT=""
PUBLISH_DIR=""
on_exit() {
  local status="$?"
  trap - EXIT
  if [ "${status}" -eq 0 ]; then
    [ -z "${RUN_ROOT}" ] || rmdir "${RUN_ROOT}" 2>/dev/null || true
  elif [ -n "${RUN_ROOT}" ] && [ -d "${RUN_ROOT}" ]; then
    echo "轉錄未完成；部分輸出保留於: ${RUN_ROOT}" >&2
  fi
  exit "${status}"
}

publish_outputs() {
  local backup_container previous
  if [ -e "${OUTDIR}" ]; then
    backup_container="$(mktemp -d "${OUTDIR_PARENT}/.transcribe-meeting-backup.XXXXXX")" || {
      echo "無法建立既有輸出的備份位置，未發布新輸出。" >&2
      return 1
    }
    previous="${backup_container}/previous"
    if ! mv "${OUTDIR}" "${previous}"; then
      rmdir "${backup_container}" 2>/dev/null || true
      echo "無法保留既有輸出，未發布新輸出。" >&2
      return 1
    fi
    if ! mv "${PUBLISH_DIR}" "${OUTDIR}"; then
      if ! mv "${previous}" "${OUTDIR}"; then
        echo "新輸出與既有輸出都無法回復；既有輸出仍在: ${previous}" >&2
      fi
      return 1
    fi
    echo "既有輸出保留於: ${previous}"
  else
    if ! mv "${PUBLISH_DIR}" "${OUTDIR}"; then
      echo "無法發布輸出: ${OUTDIR}" >&2
      return 1
    fi
  fi
}

# --- 解析引擎，失敗自動降級 ---
validate_output_target || exit 2
REQUESTED_ENGINE="${ENGINE}"
COMPARISON_CANCELLED=0

if [ "${ENGINE}" != "cpu" ] && ! { [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; }; then
  if [ "${ENGINE}" = "both" ]; then
    COMPARISON_CANCELLED=1
    echo "both：MLX 不支援此平台；比較已取消，僅執行 CPU。"
  else
    echo "非 Apple Silicon（$(uname -s)/$(uname -m)），MLX 不支援 → 改用 cpu 引擎"
  fi
  ENGINE="cpu"
fi

if [ "${ENGINE}" = "mlx" ] || [ "${ENGINE}" = "both" ]; then
  if ! prepare_mlx; then
    if [ "${REQUESTED_ENGINE}" = "both" ]; then
      COMPARISON_CANCELLED=1
      echo "both：MLX 準備失敗；比較已取消，僅執行 CPU。"
    else
      echo "MLX 準備失敗 → 改用 cpu 引擎"
    fi
    ENGINE="cpu"
  fi
fi
if [ "${ENGINE}" = "cpu" ] || [ "${ENGINE}" = "both" ]; then
  prepare_cpu || exit 1
fi

echo "模式: ${ENGINE}"
if [ "${REQUESTED_ENGINE}" != "${ENGINE}" ]; then
  echo "原要求: ${REQUESTED_ENGINE}；實際執行: ${ENGINE}"
fi
[ "${COMPARISON_CANCELLED}" -eq 1 ] && echo "結果：comparison cancelled；CPU 成功時 exit 0，CPU 失敗時 exit 1。"
[ "${ENGINE}" != "cpu" ] && echo "  mlx: ${MLXBIN}  模型=${MLX_MODEL}"
[ "${ENGINE}" != "mlx" ] && echo "  cpu: ${WHISPER}  模型=${CPU_MODEL}"

RUN_ROOT="$(mktemp -d "${OUTDIR_PARENT}/.transcribe-meeting-run.XXXXXX")" || {
  echo "無法建立暫存 run directory: ${OUTDIR_PARENT}" >&2
  exit 1
}
PUBLISH_DIR="${RUN_ROOT}/publish"
mkdir -p "${PUBLISH_DIR}"
trap on_exit EXIT

# --- (1) 測是不是混音 mono（決定能否分軌） ---
echo "檢查聲道（混音 mono 判斷）..."
MEAN="$(ffmpeg -i "${INPUT}" -af "pan=mono|c0=c0-c1,volumedetect" -f null - 2>&1 | grep mean_volume || true)"
echo "   ${MEAN}"
echo "   mean_volume 很低(接近靜音) = 左右聲道幾乎相同 = 混音 mono，無法機器分軌，說話人需靠內容判讀"

# --- (2) 轉錄 ---
ELAPSED_MLX=0
ELAPSED_CPU=0

run_mlx() {  # $1=輸出資料夾
  local start="${SECONDS}"
  mkdir -p "$1"
  # --condition-on-previous-text False 是必要的：
  # 預設 True 時，音檔尾端的 padding 會讓 decoder 陷入重複迴圈
  # （實測某段重複同一句 11 次，compression_ratio 高達 11.68 卻沒被內建閾值濾掉）。
  # 關掉後迴圈消失、速度還更快，且深處人名仍正確。
  set -- "${INPUT}" \
    --language "${WHISPER_LANG}" --model "${MLX_MODEL}" \
    --output-format all --output-dir "$1" \
    --condition-on-previous-text False --verbose False
  [ -n "${PROMPT}" ] && set -- "$@" --initial-prompt "${PROMPT}"
  "${MLXBIN}" "$@"
  ELAPSED_MLX=$(( SECONDS - start ))
}

run_cpu() {  # $1=輸出資料夾
  local start="${SECONDS}"
  mkdir -p "$1"
  set -- "${INPUT}" \
    --language "${WHISPER_LANG}" --model "${CPU_MODEL}" \
    --output_format all --output_dir "$1" --verbose False
  [ -n "${PROMPT}" ] && set -- "$@" --initial_prompt "${PROMPT}"
  "${WHISPER}" "$@"
  ELAPSED_CPU=$(( SECONDS - start ))
}

has_output_file() {
  local candidate
  for candidate in "$1"/*.$2; do
    if [ -f "${candidate}" ]; then
      return 0
    fi
  done
  return 1
}

validate_transcription_output() {
  local directory="$1"
  local label="$2"
  local extension
  local missing=""
  [ -d "${directory}" ] || {
    echo "[${label}] 輸出資料夾不存在: ${directory}" >&2
    return 1
  }
  for extension in txt srt vtt json tsv; do
    if ! has_output_file "${directory}" "${extension}"; then
      missing="${missing} .${extension}"
    fi
  done
  if [ -n "${missing}" ]; then
    echo "[${label}] 輸出不完整，缺少:${missing}" >&2
    return 1
  fi
}

process_output() {
  validate_transcription_output "$1" "$2"
  convert_traditional "$1"
  qc_report "$1" "$2" "$3"
}

# --- (3) 自動品質稽核（抓重複迴圈與壓縮率異常，省掉人工全篇掃） ---
qc_report() {  # $1=輸出資料夾 $2=標籤 $3=耗時秒
  local json candidate
  json=""
  for candidate in "$1"/*.json; do
    if [ -f "${candidate}" ]; then
      json="${candidate}"
      break
    fi
  done
  if [ -z "${json}" ]; then
    echo "  ($2: 找不到 json，品質稽核失敗)" >&2
    return 1
  fi
  python3 - "${json}" "$2" "$3" "${DUR}" <<'PY'
import json, sys

jsonp, label, elapsed, dur = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
segs = json.load(open(jsonp, encoding="utf-8")).get("segments", [])
print(f"\n--- 品質稽核 [{label}] ---")
if not segs:
    print("無 segment（音檔可能是空的），略過"); sys.exit(0)

# 連續重複同一句 >=3 次 = decoder 陷入迴圈
runs, prev, n = [], None, 0
for s in segs:
    t = s["text"].strip()
    if t == prev:
        n += 1
    else:
        if n >= 3: runs.append((prev, n))
        prev, n = t, 1
if n >= 3: runs.append((prev, n))

bad_cr = [s for s in segs if s.get("compression_ratio", 0) > 2.4]
PATS = ["尼泊爾", "字幕", "訂閱", "請不吝", "點贊", "明鏡", "謝謝觀看", "小編"]
txt = "".join(s["text"] for s in segs)
hall = [p for p in PATS if p in txt]

if dur and elapsed:
    print(f"音檔 {dur/60:.1f} 分鐘 / 耗時 {elapsed//60}分{elapsed%60}秒 ({dur/elapsed:.1f}x realtime)")
print(f"段數 {len(segs)}，覆蓋到 {segs[-1]['end']:.1f}s" + (f" / 音檔 {dur:.1f}s" if dur else ""))
print(f"重複迴圈: {len(runs)} 處" + (" ✅" if not runs else " ⚠️  需人工確認"))
for t, k in runs[:5]:
    print(f"   x{k}: {t[:50]}")
print(f"compression_ratio>2.4: {len(bad_cr)} 段" + (" ✅" if not bad_cr else " ⚠️"))
for s in bad_cr[:5]:
    print(f"   [{s['start']:.1f}s] cr={s['compression_ratio']:.2f} {s['text'].strip()[:50]}")
print(f"幻覺樣式: {hall if hall else '✅ 無命中'}")
PY
}

# --- (4) both 模式：並排比較 ---
compare_report() {  # $1=mlx 資料夾 $2=cpu 資料夾
  python3 - "$1" "$2" "${ELAPSED_MLX}" "${ELAPSED_CPU}" <<'PY'
import difflib, glob, json, re, sys, unicodedata

def w(s):  # 顯示寬度：全形字佔 2 欄，否則表格會歪
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)

def pad(s, n):
    return s + " " * max(0, n - w(s))

def rpad(s, n):
    return " " * max(0, n - w(s)) + s

def load(d):
    j = sorted(glob.glob(f"{d}/*.json"), key=lambda p: -len(p))
    t = sorted(glob.glob(f"{d}/*.txt"), key=lambda p: -len(p))
    if not j or not t: return None
    segs = json.load(open(j[0], encoding="utf-8")).get("segments", [])
    raw = open(t[0], encoding="utf-8").read()
    return segs, re.sub(r"[\s，。、？！,.?!]", "", raw)

a, b = load(sys.argv[1]), load(sys.argv[2])
em, ec = int(sys.argv[3]), int(sys.argv[4])
print("\n=========== 引擎並排比較 ===========")
if not a or not b:
    print("有一邊缺輸出，無法比較", file=sys.stderr); sys.exit(1)
(msegs, mtxt), (csegs, ctxt) = a, b
sim = difflib.SequenceMatcher(None, ctxt, mtxt).ratio() * 100

def fmt(s): return f"{s//60}分{s%60}秒"
def row(label, mv, cv):
    print(pad(label, 14) + rpad(str(mv), 12) + rpad(str(cv), 12))

row("", "mlx", "cpu")
row("耗時", fmt(em), fmt(ec))
if em and ec:
    row("加速倍數", f"{ec/em:.1f}x", "(基準)")
row("段數", len(msegs), len(csegs))
row("正規化字數", len(mtxt), len(ctxt))
print(f"\n兩者逐字稿相似度: {sim:.1f}%")

sm = difflib.SequenceMatcher(None, ctxt, mtxt)
diffs = []
for tag, i1, i2, j1, j2 in sm.get_opcodes():
    if tag == "replace" and max(i2 - i1, j2 - j1) >= 8:
        diffs.append(("兩者不同", ctxt[i1:i2][:60], mtxt[j1:j2][:60]))
    elif tag == "delete" and i2 - i1 >= 8:
        diffs.append(("只 cpu 有", ctxt[i1:i2][:60], ""))
    elif tag == "insert" and j2 - j1 >= 8:
        diffs.append(("只 mlx 有", "", mtxt[j1:j2][:60]))
print(f"實質差異片段 (>=8字): {len(diffs)} 處" + (" ✅" if not diffs else ""))
for kind, c, m in diffs[:10]:
    print(f"  [{kind}]")
    if c: print(f"     cpu: {c}")
    if m: print(f"     mlx: {m}")
print("\n判讀：相似度 >85% 且實質差異多為語助詞 → mlx 可安心當預設。")
print("      若出現整段內容只在一邊 → 該段請人工聽一次確認。")
PY
}

if [ "${ENGINE}" = "both" ]; then
  echo
  echo "=== [1/2] mlx 引擎 ==="
  run_mlx "${PUBLISH_DIR}/mlx"
  process_output "${PUBLISH_DIR}/mlx" "mlx" "${ELAPSED_MLX}"
  echo
  if [ "${DUR}" != "0" ]; then
    echo "=== [2/2] cpu 引擎（預估約 $(python3 -c "print(f'{${DUR}*1.34/60:.0f}')") 分鐘，會吃滿 CPU）==="
  else
    echo "=== [2/2] cpu 引擎（會吃滿 CPU，請耐心等）==="
  fi
  run_cpu "${PUBLISH_DIR}/cpu"
  process_output "${PUBLISH_DIR}/cpu" "cpu" "${ELAPSED_CPU}"
  # 兩邊都轉繁後才比較，差異才是真的內容差異而非繁簡不一致
  compare_report "${PUBLISH_DIR}/mlx" "${PUBLISH_DIR}/cpu"
elif [ "${ENGINE}" = "mlx" ]; then
  echo "開始轉錄 lang=${WHISPER_LANG} 首次會下載模型(~1.5GB)..."
  run_mlx "${PUBLISH_DIR}"
  process_output "${PUBLISH_DIR}" "mlx" "${ELAPSED_MLX}"
else
  echo "開始轉錄 lang=${WHISPER_LANG} 首次會下載模型(~1.5GB)..."
  run_cpu "${PUBLISH_DIR}"
  process_output "${PUBLISH_DIR}" "cpu" "${ELAPSED_CPU}"
fi

publish_outputs
echo
if [ "${COMPARISON_CANCELLED}" -eq 1 ]; then
  echo "完成 -> ${OUTDIR}（原要求 ${REQUESTED_ENGINE}；比較已取消，僅發布 CPU 輸出）"
elif [ "${ENGINE}" = "both" ]; then
  echo "完成 -> ${OUTDIR}/mlx 與 ${OUTDIR}/cpu (各含 .txt/.srt/.vtt/.json/.tsv)"
else
  echo "完成 -> ${OUTDIR} (產出 .txt/.srt/.vtt/.json/.tsv)"
fi
echo "提醒：近靜音段 Whisper 仍可能生幻覺，上面稽核只抓常見樣式；交稿前建議快速掃一遍。"
