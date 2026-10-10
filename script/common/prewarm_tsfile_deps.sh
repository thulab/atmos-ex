#!/usr/bin/env bash
set -o pipefail

# 功能：预置 TsFile Cpp/Python 构建的本地依赖缓存，避免构建时联网下载依赖超时。
#       解析 tsfile 源码 cpp/cmake/*Source.cmake 声明的依赖归档（名称/URL/SHA256），
#       把缺失的归档下载到缓存目录并做 SHA256 校验。
#       与 tsfile_api_test.sh 配合：构建脚本检测到缓存目录后追加
#       -Dtsfile.dependency.cache=... -Dtsfile.dependency.offline=true，构建全程零联网。
# 用法：
#   bash script/common/prewarm_tsfile_deps.sh [--tsfile <tsfile源码目录>] [--cache <缓存目录>] [--check]
#     --tsfile  TsFile 源码目录，默认取环境变量 TSFILE_PATH（缺省 /data/atmos/zk_test/tsfile）
#     --cache   依赖缓存目录，默认取环境变量 TSFILE_DEPS_CACHE（缺省 /data/atmos/zk_test/deps-local）
#     --check   只校验缓存完整性（不下载），缺失或校验和不符时退出码非 0
# 说明：下载遵循 HTTP_PROXY/HTTPS_PROXY 环境变量（curl 自动读取）。

TSFILE_PATH="${TSFILE_PATH:-/data/atmos/zk_test/tsfile}"
CACHE_DIR="${TSFILE_DEPS_CACHE:-/data/atmos/zk_test/deps-local}"
CHECK_ONLY=0

# 功能：打印用法
usage() {
	cat <<'EOF'
用法: bash prewarm_tsfile_deps.sh [--tsfile <tsfile源码目录>] [--cache <缓存目录>] [--check]
  --tsfile  TsFile 源码目录，默认 ${TSFILE_PATH:-/data/atmos/zk_test/tsfile}
  --cache   依赖缓存目录，默认 ${TSFILE_DEPS_CACHE:-/data/atmos/zk_test/deps-local}
  --check   只校验缓存完整性（不下载）
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--tsfile)
			TSFILE_PATH="${2:-}"
			shift 2
			;;
		--cache)
			CACHE_DIR="${2:-}"
			shift 2
			;;
		--check)
			CHECK_ONLY=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			printf '[prewarm] 未知参数: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
done

if [ ! -d "${TSFILE_PATH}/cpp/cmake" ]; then
	printf '[prewarm] [FAIL] 找不到 TsFile cmake 目录: %s/cpp/cmake\n' "${TSFILE_PATH}" >&2
	exit 2
fi

DEFS_FILE="$(mktemp "${TMPDIR:-/tmp}/tsfile_deps.XXXXXX")"
trap 'rm -f "${DEFS_FILE}"' EXIT

# 功能：提取 cmake 文件中的 set(NAME VALUE) 定义（支持跨行写法），输出 NAME<TAB>VALUE
extract_sets() {
	awk '
	{
		if ($0 ~ /^[[:space:]]*set\(/) {
			buf = $0
			while (buf !~ /\)/) {
				if ((getline nxt) <= 0) {
					break
				}
				buf = buf " " nxt
			}
			if (match(buf, /^[[:space:]]*set\([A-Za-z0-9_]+[[:space:]]+/)) {
				t = buf
				sub(/^[[:space:]]*set\(/, "", t)
				n = t
				sub(/[[:space:]].*$/, "", n)
				if (match(t, /"[^"]*"/)) {
					v = substr(t, RSTART + 1, RLENGTH - 2)
				} else {
					v = t
					sub(/^[^[:space:]]+[[:space:]]*/, "", v)
					sub(/\).*$/, "", v)
				}
				print n "\t" v
			}
		}
	}
	' "$1"
}

# 功能：收集 tsfile cmake 中的变量定义
collect_defs() {
	local f
	for f in "${TSFILE_PATH}"/cpp/cmake/*Source.cmake \
		"${TSFILE_PATH}"/cpp/cmake/*Dependency.cmake \
		"${TSFILE_PATH}"/cpp/CMakeLists.txt; do
		[ -f "${f}" ] || continue
		extract_sets "${f}" >>"${DEFS_FILE}"
	done
}

# 功能：查询变量定义值
lookup() {
	awk -F'\t' -v key="$1" '$1 == key { print $2; exit }' "${DEFS_FILE}"
}

# 功能：解析字符串中的 ${VAR} 引用（变量值来自 cmake 定义），解析失败返回非 0
resolve() {
	local s="$1" var val guard=0
	while [[ "${s}" =~ \$\{([A-Za-z0-9_]+)\} ]]; do
		var="${BASH_REMATCH[1]}"
		val="$(lookup "${var}")"
		if [ -z "${val}" ]; then
			return 1
		fi
		s="${s//\$\{${var}\}/${val}}"
		guard=$((guard + 1))
		if [ "${guard}" -ge 20 ]; then
			return 1
		fi
	done
	printf '%s' "${s}"
}

collect_defs

proxy="${HTTPS_PROXY:-${HTTP_PROXY:-}}"
proxy_args=()
if [ -n "${proxy}" ]; then
	proxy_args=(--proxy "${proxy}")
fi

if [ "${CHECK_ONLY}" -eq 1 ]; then
	mode='校验模式（不下载）'
else
	mode='下载模式'
	mkdir -p "${CACHE_DIR}" || {
		printf '[prewarm] [FAIL] 无法创建缓存目录: %s\n' "${CACHE_DIR}" >&2
		exit 2
	}
fi
printf '[prewarm] tsfile=%s\n' "${TSFILE_PATH}"
printf '[prewarm] cache=%s\n' "${CACHE_DIR}"
printf '[prewarm] mode=%s proxy=%s\n' "${mode}" "${proxy:-无}"

total=0
ready=0
downloaded=0
failed=0
skipped=0
while IFS= read -r prefix; do
	total=$((total + 1))
	a_name="$(lookup "${prefix}_ARCHIVE_NAME")"
	a_sha="$(lookup "${prefix}_SHA256")"
	a_url="$(lookup "${prefix}_URL")"
	if [ -z "${a_name}" ] || [ -z "${a_sha}" ] || [ -z "${a_url}" ]; then
		printf '[prewarm] [SKIP] %s: cmake 中缺少 ARCHIVE_NAME/SHA256/URL 定义\n' "${prefix}"
		skipped=$((skipped + 1))
		continue
	fi
	if ! r_name="$(resolve "${a_name}")"; then
		printf '[prewarm] [SKIP] %s: 归档名变量无法解析\n' "${prefix}"
		skipped=$((skipped + 1))
		continue
	fi
	if ! r_url="$(resolve "${a_url}")"; then
		printf '[prewarm] [SKIP] %s: URL 变量无法解析（可能为当前未启用模式的依赖）\n' "${prefix}"
		skipped=$((skipped + 1))
		continue
	fi
	archive="${CACHE_DIR}/${r_name}"
	if [ -f "${archive}" ] && [ "$(sha256sum "${archive}" | awk '{print $1}')" = "${a_sha}" ]; then
		printf '[prewarm] [OK] %s\n' "${r_name}"
		ready=$((ready + 1))
		continue
	fi
	if [ "${CHECK_ONLY}" -eq 1 ]; then
		printf '[prewarm] [MISS] %s\n' "${r_name}"
		failed=$((failed + 1))
		continue
	fi
	partial="${archive}.part"
	rm -f "${partial}"
	printf '[prewarm] [DL] %s\n' "${r_name}"
	dl_ok=0
	for attempt in 1 2 3; do
		if curl -sS -L --fail --http1.1 --connect-timeout 20 --max-time 900 \
			"${proxy_args[@]}" -o "${partial}" "${r_url}"; then
			dl_ok=1
			break
		fi
		rm -f "${partial}"
		printf '[prewarm] [DL] %s: 第 %s 次尝试失败，5 秒后重试\n' "${r_name}" "${attempt}"
		sleep 5
	done
	if [ "${dl_ok}" -ne 1 ]; then
		rm -f "${partial}"
		printf '[prewarm] [FAIL] %s: 下载失败（URL: %s）\n' "${r_name}" "${r_url}"
		failed=$((failed + 1))
		continue
	fi
	actual_sha="$(sha256sum "${partial}" | awk '{print $1}')"
	if [ "${actual_sha}" = "${a_sha}" ]; then
		mv -f "${partial}" "${archive}"
		printf '[prewarm] [OK] %s（已下载）\n' "${r_name}"
		downloaded=$((downloaded + 1))
	else
		rm -f "${partial}"
		printf '[prewarm] [FAIL] %s: SHA256 校验不符（expected %s, actual %s）\n' \
			"${r_name}" "${a_sha}" "${actual_sha}"
		failed=$((failed + 1))
	fi
done < <(awk -F'\t' '
	$1 ~ /^_TSFILE_[A-Za-z0-9_]*_ARCHIVE_NAME$/ {
		sub(/_ARCHIVE_NAME$/, "", $1)
		print $1
	}
	' "${DEFS_FILE}" | sort -u)

printf '[prewarm] 汇总：声明=%d 就绪=%d 新下载=%d 失败=%d 跳过=%d\n' \
	"${total}" "${ready}" "${downloaded}" "${failed}" "${skipped}"
if [ "${failed}" -gt 0 ]; then
	exit 1
fi
exit 0
